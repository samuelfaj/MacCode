import XCTest
@testable import Persistence
import CoreModel

final class PersistenceTests: XCTestCase {
    func test_bootstrap_freshStart_isEmpty_andTouchesOnlyOwnedPaths() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bs = Bootstrap(channel: .debug, appSupportOverride: tmp)
        let (rep, db) = try bs.run()
        XCTAssertTrue(rep.firstRun)
        XCTAssertEqual(rep.schemaVersion, Schema.currentVersion)
        let schemaStmt = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try schemaStmt.step())
        XCTAssertEqual(Int(schemaStmt.columnInt64(0)), Schema.currentVersion,
                       "bootstrap must report the same schema version that migration actually records, otherwise restart diagnostics can lie about persistence shape")
        // touchedPaths only inside tmp
        for path in rep.touchedPaths {
            XCTAssertTrue(path.hasPrefix(tmp), "touched path \(path) escapes \(tmp)")
        }
        // tables empty
        let projects = try ProjectRepository(db: db).list()
        XCTAssertTrue(projects.isEmpty)
        let threads = try AgentThreadRepository(db: db).list()
        XCTAssertTrue(threads.isEmpty)
    }

    func test_bootstrapDefaultsRemoteAccessOffUntilExplicitOptIn() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()

        let value = try SettingsRepository(db: db).get("remote_access_enabled")
        XCTAssertEqual(value, "0", "LAN pairing must require explicit opt-in before the Mac advertises itself.")
    }

    func test_schemaIsIdempotent() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bs = Bootstrap(channel: .debug, appSupportOverride: tmp)
        _ = try bs.run()
        // re-open and migrate again
        let (rep2, _) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        XCTAssertFalse(rep2.firstRun)
    }

    func test_threadAndMessage_roundtrip() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        var t = AgentThread(workspaceId: WorkspaceID(), title: "demo", provider: .codex, model: "gpt-5")
        t.providerInstanceId = "codex-personal"
        t.executionMode = .worktree
        t.baseBranch = "main"
        t.worktreePath = "/tmp/rc-agent-worktree"
        t.serviceTier = .fast
        t.modelSelection = AgentModelSelection(provider: .codex,
                                               modelId: "",
                                               customModelId: "gpt-5.5-experimental",
                                               reasoningEffort: .xhigh,
                                               serviceTier: .fast)
        try tr.upsert(t)
        let list = try tr.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "demo")
        XCTAssertEqual(list[0].providerInstanceId, "codex-personal",
                       "provider instance id must persist on threads so future personal/work providers cannot mix continuation state")
        XCTAssertEqual(list[0].executionMode, .worktree,
                       "agent thread execution mode must persist so first-send worktree routing survives app restart")
        XCTAssertEqual(list[0].baseBranch, "main")
        XCTAssertEqual(list[0].worktreePath, "/tmp/rc-agent-worktree")
        XCTAssertEqual(list[0].serviceTier, .fast,
                       "agent service tier must persist so Codex fast mode survives app restart")
        XCTAssertEqual(list[0].modelSelection.modelId, "")
        XCTAssertEqual(list[0].modelSelection.customModelId, "gpt-5.5-experimental")
        XCTAssertEqual(list[0].modelSelection.effectiveModel, "gpt-5.5-experimental",
                       "custom model selection must persist as structured data so restart does not flatten it into a loose model string")
        XCTAssertEqual(list[0].modelSelection.reasoningEffort, .xhigh)
        XCTAssertEqual(list[0].modelSelection.serviceTier, .fast)

        let mr = AgentMessageRepository(db: db)
        try mr.append(AgentMessage(threadId: t.id, role: .user, content: "hi"))
        try mr.append(AgentMessage(threadId: t.id, role: .assistant, content: "hello"))
        let msgs = try mr.list(threadId: t.id)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)

        let runs = AgentRunRepository(db: db)
        let run = AgentRun(threadId: t.id, provider: .codex, providerInstanceId: "codex-personal", model: "gpt-5", status: .cancelled, finishedAt: Date(), terminalReason: "userStop")
        try runs.upsert(run)
        XCTAssertEqual(try runs.get(id: run.id)?.providerInstanceId, "codex-personal",
                       "provider instance id must persist on runs so recovery/debugging can identify the exact provider identity used")
        XCTAssertEqual(try runs.get(id: run.id)?.terminalReason, "userStop")
    }

    func test_agentMessageRepositoryPagesOlderHistoryWithStableCursor() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(title: "long history", provider: .codex, model: "gpt-5")
        try tr.upsert(t)
        let mr = AgentMessageRepository(db: db)
        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        for index in 0..<35 {
            let id = AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
            try mr.append(AgentMessage(
                id: id,
                threadId: t.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(index)",
                createdAt: base.addingTimeInterval(TimeInterval(index / 2))
            ))
        }

        let first = try mr.listPage(threadId: t.id, limit: 10, before: nil)
        let older = try mr.listPage(threadId: t.id, limit: 30, before: first.nextBefore)

        XCTAssertEqual(first.messages.map(\.content), (25..<35).map { "message-\($0)" },
                       "initial history page must return the newest 10 in display order")
        XCTAssertTrue(first.hasMoreOlder)
        XCTAssertEqual(older.messages.map(\.content), (0..<25).map { "message-\($0)" },
                       "older page must use created_at plus id as the cursor so duplicate timestamps do not skip rows")
        XCTAssertFalse(older.hasMoreOlder)

        let newer = try mr.listPage(threadId: t.id, limit: 10, before: nil, after: older.nextAfter)
        XCTAssertEqual(newer.messages.map(\.content), (25..<35).map { "message-\($0)" },
                       "newer page must use created_at plus id as the cursor so viewport-only history can reload rows below the current scroll position")
        XCTAssertFalse(newer.hasMoreNewer)
    }

    func test_snapshot_roundtrip() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: SurfaceDescriptor(type: .agentApp, title: "a")))
        let snap = SessionSnapshot(layout: s)
        let repo = SessionSnapshotRepository(db: db)
        try repo.save(snap)
        let loaded = try XCTUnwrap(try repo.latest())
        XCTAssertEqual(loaded.layout.window.workspaces.count, 1)
    }

    func test_runReconcile_marksRunningAsInterrupted() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let runs = AgentRunRepository(db: db)
        let r = AgentRun(threadId: AgentThreadID(), provider: .codex, model: "m", status: .running)
        // need parent thread row to satisfy FK
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(id: r.threadId, title: "t", provider: .codex, model: "m")
        try tr.upsert(t)
        try runs.upsert(r)
        let count = try runs.reconcileRunningOnLaunch()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try runs.get(id: r.id)?.terminalReason, "relaunchReconcile")
    }

    func test_providerSessionRuntime_roundtripsRecoveryStateAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2ProviderSession-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threads = AgentThreadRepository(db: db)
            let thread = AgentThread(title: "resume", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            try threads.upsert(thread)
            try ProviderSessionRuntimeRepository(db: db).upsert(ProviderSessionRuntime(
                threadId: thread.id,
                provider: .codex,
                providerInstanceId: "default",
                adapterKey: "CodexSessionRuntime",
                binaryIdentity: "codex:/opt/homebrew/bin/codex",
                status: .completed,
                resumeCursor: "codex-thread-1",
                cwd: "/tmp/remote-code",
                model: "gpt-5.5",
                serviceTier: .fast,
                runtimeMode: .autoAcceptEdits,
                lastEventKind: "turn.completed",
                runtimePayloadJSON: #"{"turnCount":1}"#
            ))
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = ProviderSessionRuntimeRepository(db: reopened)
        let session = try XCTUnwrap(try repo.get(threadId: threadId))
        XCTAssertEqual(session.resumeCursor, "codex-thread-1",
                       "provider resume cursor must survive app restart so long-running agent sessions can continue")
        XCTAssertEqual(session.cwd, "/tmp/remote-code")
        XCTAssertEqual(session.model, "gpt-5.5")
        XCTAssertEqual(session.serviceTier, .fast)
        XCTAssertEqual(session.runtimeMode, .autoAcceptEdits)
        XCTAssertEqual(session.adapterKey, "CodexSessionRuntime")
        XCTAssertEqual(session.binaryIdentity, "codex:/opt/homebrew/bin/codex")
        XCTAssertEqual(session.lastEventKind, "turn.completed")
        XCTAssertEqual(session.runtimePayloadJSON, #"{"turnCount":1}"#,
                       "provider runtime payload must survive app restart so exact provider resume metadata is not reduced to diagnostics")
        XCTAssertEqual(try repo.recoveryState(threadId: threadId), .recoverable(session),
                       "completed sessions with a resume cursor must be classified as recoverable, not silently lost")
    }

    func test_updateDiagnostics_skipsNoOpUpsertWhileStreamingSameKind() throws {
        // WHY: persistStreamBatch calls updateDiagnostics on every 16-event /
        // 250ms flush. Token deltas on one item keep lastEventKind as
        // `itemDelta(id)` but used to rewrite the whole provider_session_runtime
        // row (runtime_payload_json included) just to bump updatedAt.
        let tmp = NSTemporaryDirectory() + "RC2DiagnosticsNoOp-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "stream", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let repo = ProviderSessionRuntimeRepository(db: db)
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = String(repeating: "x", count: 8_192)
        try repo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            lastEventKind: "itemDelta(item-1)",
            runtimePayloadJSON: payload,
            updatedAt: frozen
        ))

        var upserts = 0
        var diagnosticUpdates = 0
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("INSERT INTO provider_session_runtime") {
                upserts += 1
            }
            if sql.contains("UPDATE provider_session_runtime") && sql.contains("last_event_kind") {
                diagnosticUpdates += 1
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-1)",
            lastErrorMessage: nil,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(upserts, 0, "same lastEventKind must not WAL-write the session row")
        XCTAssertEqual(diagnosticUpdates, 0, "same lastEventKind must not UPDATE diagnostics")
        XCTAssertEqual(
            repo.diagnosticsLoadCountForTesting, 0,
            "upsert already remembered diagnostics; same-kind flush must not SELECT runtime_payload_json"
        )
        let afterNoop = try XCTUnwrap(try repo.get(threadId: thread.id))
        XCTAssertEqual(afterNoop.lastEventKind, "itemDelta(item-1)")
        XCTAssertEqual(afterNoop.updatedAt.timeIntervalSince1970, frozen.timeIntervalSince1970,
                       "updatedAt must stay put so skip is observable; reaper only lists completed sessions")
        XCTAssertEqual(afterNoop.runtimePayloadJSON, payload)

        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-2)",
            lastErrorMessage: nil,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(upserts, 0, "a new lastEventKind must not rewrite the full row")
        XCTAssertEqual(diagnosticUpdates, 1, "a new lastEventKind must still persist")
        XCTAssertEqual(repo.diagnosticsLoadCountForTesting, 0, "kind change must not SELECT runtime_payload_json")
        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-2)",
            lastErrorMessage: nil,
            at: Date(timeIntervalSince1970: 1_850_000_000)
        )
        XCTAssertEqual(repo.diagnosticsLoadCountForTesting, 0, "repeat same kind after write must not SELECT again")
        XCTAssertEqual(diagnosticUpdates, 1, "repeat same kind after write must not UPDATE again")
        let afterChange = try XCTUnwrap(try repo.get(threadId: thread.id))
        XCTAssertEqual(afterChange.lastEventKind, "itemDelta(item-2)")
        XCTAssertEqual(afterChange.updatedAt.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(afterChange.runtimePayloadJSON, payload)

        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-2)",
            lastErrorMessage: "boom",
            at: Date(timeIntervalSince1970: 1_900_000_000)
        )
        XCTAssertEqual(upserts, 0, "a new lastErrorMessage must not rewrite the full row")
        XCTAssertEqual(diagnosticUpdates, 2, "a new lastErrorMessage must still persist")
        XCTAssertEqual(repo.diagnosticsLoadCountForTesting, 0, "error change must not SELECT runtime_payload_json")
        let afterError = try XCTUnwrap(try repo.get(threadId: thread.id))
        XCTAssertEqual(afterError.lastErrorMessage, "boom")
        XCTAssertEqual(afterError.lastEventKind, "itemDelta(item-2)")
        XCTAssertEqual(afterError.runtimePayloadJSON, payload)
    }

    func test_interruptedProviderSessionWithCursorIsRecoverableButCancelledSessionIsStopped() throws {
        let tmp = NSTemporaryDirectory() + "RC2InterruptedRecovery-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "resume after relaunch", provider: .codex, model: "gpt-5.5")
        try AgentThreadRepository(db: db).upsert(thread)
        let repo = ProviderSessionRuntimeRepository(db: db)
        let session = ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "codex-resume-cursor"
        )
        try repo.upsert(session)

        guard case .recoverable(let recovered) = try repo.recoveryState(threadId: thread.id) else {
            return XCTFail("a launch-interrupted provider session with a cursor must expose Continue instead of becoming an unreachable stopped session")
        }
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertEqual(recovered.resumeCursor, "codex-resume-cursor")

        try repo.markStopped(threadId: thread.id)
        guard case .stopped(let stopped) = try repo.recoveryState(threadId: thread.id) else {
            return XCTFail("an intentional stop must remain stopped even when the old provider cursor is retained")
        }
        XCTAssertEqual(stopped.status, .cancelled)
        XCTAssertEqual(stopped.resumeCursor, "codex-resume-cursor")
    }

    func test_proposedPlan_roundtripsIndependentlyFromMessagesAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2ProposedPlan-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let thread = AgentThread(title: "plan", provider: .claude, model: "sonnet")
            threadId = thread.id
            try AgentThreadRepository(db: db).upsert(thread)
            try AgentMessageRepository(db: db).append(AgentMessage(threadId: thread.id, role: .assistant, content: "normal assistant text"))
            try AgentProposedPlanRepository(db: db).upsert(
                threadId: thread.id,
                plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
            )
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let plans = try AgentProposedPlanRepository(db: reopened).list(threadId: threadId)
        let messages = try AgentMessageRepository(db: reopened).list(threadId: threadId)

        XCTAssertEqual(plans.map(\.plan.markdown), ["1. Inspect\n2. Patch"],
                       "proposed plans must survive restart as structured artifacts, not only as assistant chat text")
        XCTAssertEqual(messages.map(\.content), ["normal assistant text"],
                       "plan artifacts must stay separate from normal assistant messages")
    }

    func test_turnCheckpoint_roundtripsFilesAndProviderTurnCountAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2TurnCheckpoint-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let thread = AgentThread(title: "checkpoint", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            let runId = AgentRunID()
            try AgentThreadRepository(db: db).upsert(thread)
            try AgentRunRepository(db: db).upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
            try AgentTurnCheckpointRepository(db: db).upsert(AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: runId,
                turnId: "turn-1",
                checkpointTurnCount: 1,
                checkpointRef: "local-diff:\(runId.value.uuidString):turn-1",
                status: .ready,
                files: [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 3, deletions: 1)]
            ))
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let checkpoints = try AgentTurnCheckpointRepository(db: reopened).list(threadId: threadId)

        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints[0].turnId, "turn-1")
        XCTAssertEqual(checkpoints[0].checkpointTurnCount, 1,
                       "checkpoint turn count must survive restart so provider turns can be matched to workspace checkpoints")
        XCTAssertEqual(checkpoints[0].status, .ready)
        XCTAssertEqual(checkpoints[0].files, [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 3, deletions: 1)],
                       "checkpoint file summaries must survive as structured data, not only as display text")
    }

    func test_turnCheckpointCorruptionReportsSkippedRowsWithoutDroppingHealthyData() throws {
        let tmp = NSTemporaryDirectory() + "RC2TurnCheckpointCorrupt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "checkpoint corrupt", provider: .codex, model: "gpt-5.5")
        let runId = AgentRunID()
        try AgentThreadRepository(db: db).upsert(thread)
        try AgentRunRepository(db: db).upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try AgentTurnCheckpointRepository(db: db).upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runId,
            turnId: "turn-corrupt",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runId.value.uuidString):turn-corrupt",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 3, deletions: 1)]
        ))
        try db.execute("UPDATE agent_turn_checkpoints SET file_snapshots_json = '{broken json' WHERE turn_id = 'turn-corrupt';")

        let result = try AgentTurnCheckpointRepository(db: db).listTolerant(threadId: thread.id)
        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 1,
                       "corrupt checkpoint snapshot JSON must be counted so restore diagnostics fail loud without hiding other healthy checkpoints")
        XCTAssertEqual(try AgentTurnCheckpointRepository(db: db).list(threadId: thread.id), [],
                       "legacy list() should skip corrupt rows while listTolerant reports the skipped-row count")
    }

    func test_commandReceipt_roundtripsAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2CommandReceipt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            try CommandReceiptRepository(db: db).record(
                method: "agent.message.send",
                clientRequestId: "mobile-send-1",
                resultJSON: #"{"run_id":"run-1"}"#
            )
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        XCTAssertEqual(
            try CommandReceiptRepository(db: reopened).get(method: "agent.message.send", clientRequestId: "mobile-send-1"),
            #"{"run_id":"run-1"}"#,
            "agent command receipts must survive app restart so mobile retries cannot duplicate long-running provider turns"
        )
    }

    func test_providerPendingCallbacks_roundtripResolveAndStaleAcrossRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2PendingCallbacks-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let thread = AgentThread(title: "callbacks", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            try AgentThreadRepository(db: db).upsert(thread)
            let repo = ProviderPendingCallbackRepository(db: db)
            try repo.record(threadId: thread.id, request: AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "Run command",
                detail: "swift test",
                createdAtMs: 1_000
            ))
            try repo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
                id: "question-1",
                turnId: "turn-1",
                prompt: "Continue?",
                options: ["Plan", "Run"],
                createdAtMs: 2_000
            ))
            try repo.resolve(threadId: thread.id, requestId: "approval-1", kind: .approval, state: .approved)
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = ProviderPendingCallbackRepository(db: reopened)
        let approval = try XCTUnwrap(try repo.get(threadId: threadId, requestId: "approval-1", kind: .approval))
        XCTAssertEqual(approval.state, .approved,
                       "approval callback decisions must persist so retry/reload does not resurrect a resolved approval")
        let staleCount = try repo.markOpenStale(reason: "Provider callback state does not survive app restart.")
        let question = try XCTUnwrap(try repo.get(threadId: threadId, requestId: "question-1", kind: .userInput))
        XCTAssertEqual(staleCount, 1)
        XCTAssertEqual(question.state, .stale,
                       "open provider questions must become explicitly stale after restart instead of leaving dead UI")
        XCTAssertEqual(question.staleReason, "Provider callback state does not survive app restart.")
    }

    func test_streamEventReplayIncludesEveryRunForThread() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "history", provider: .codex, model: "m")
        try threads.upsert(thread)

        let firstRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        let secondRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 2))
        try runs.upsert(firstRun)
        try runs.upsert(secondRun)
        try runs.appendStreamEvent(runId: firstRun.id, seq: 1, kind: "turnStarted(first)", payloadJSON: #"{"turnStarted":{"turnId":"first"}}"#)
        try runs.appendStreamEvent(runId: firstRun.id, seq: 2, kind: "error(first)", payloadJSON: #"{"error":{"message":"first update","recoverable":false}}"#)
        try runs.appendStreamEvent(runId: secondRun.id, seq: 1, kind: "turnStarted(second)", payloadJSON: #"{"turnStarted":{"turnId":"second"}}"#)

        let replayed = try runs.listLatestStreamEvents(threadId: thread.id)

        XCTAssertEqual(replayed, [
            .turnStarted(turnId: "first"),
            .error(message: "first update", recoverable: false),
            .turnStarted(turnId: "second")
        ], "reopening or following up must replay every persisted run event, not only the latest response")
    }

    func test_persistStreamBatch_formatsCreatedAtOnceForTheFlush() throws {
        // WHY: persistStreamBatch used to iso.string(from: Date()) on every
        // stream + provider INSERT. ISO8601 is second-precision, so a 16-event
        // / 250ms flush already stored the same created_at; the extra formats
        // were lock+calendar under the SQLite writer.
        let tmp = NSTemporaryDirectory() + "RC2BatchCreatedAt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "flush", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)

        var items: [AgentRunRepository.StreamWriteIntent] = []
        for seq in 1...16 {
            items.append(AgentRunRepository.StreamWriteIntent(
                seq: seq,
                kind: "itemDelta(i1)",
                payloadJSON: #"{"itemDelta":{"itemId":"i1"}}"#,
                providerEvent: ProviderRuntimeEvent(
                    id: "evt-\(seq)",
                    provider: .codex,
                    source: "test",
                    method: "event",
                    payloadJSON: #"{"i":\#(seq)}"#,
                    receivedAtMs: Int64(seq)
                )
            ))
        }

        XCTAssertEqual(runs.streamBatchISO8601FormatCountForTesting, 0)
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: items,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.streamBatchISO8601FormatCountForTesting, 1,
            "one 16-event flush must format created_at once, not once per stream/provider row"
        )

        let created = try db.prepare(
            "SELECT DISTINCT created_at FROM agent_stream_events WHERE run_id = ?;"
        )
        try created.bind(1, run.id.value.uuidString)
        var stamps: [String] = []
        while try created.step() {
            stamps.append(created.columnText(0) ?? "")
        }
        XCTAssertEqual(stamps.count, 1, "all flushed stream rows must share the batch created_at")
        XCTAssertFalse(stamps[0].isEmpty)

        let providerStamps = try db.prepare(
            "SELECT DISTINCT created_at FROM agent_provider_event_logs WHERE thread_id = ?;"
        )
        try providerStamps.bind(1, thread.id.value.uuidString)
        var provider: [String] = []
        while try providerStamps.step() {
            provider.append(providerStamps.columnText(0) ?? "")
        }
        XCTAssertEqual(provider, stamps, "paired provider rows must reuse the same batch timestamp")
    }

    func test_persistStreamBatch_decodesOnlyPossibleDurableHostMetadata() throws {
        // WHY: ordinary token-rate stream rows cannot create a durable host
        // attestation, so decoding all 16 rows in every flush adds JSON work
        // under the SQLite writer. A conservatively escaped discriminator must
        // still reach the authoritative decoder and durable ledger.
        let tmp = NSTemporaryDirectory() + "RC2HostMetadataScreen-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "host metadata screen", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)

        let ordinary = (1...16).map { seq in
            AgentRunRepository.StreamWriteIntent(
                seq: seq,
                kind: "itemDelta(i1)",
                payloadJSON: #"{"itemDelta":{"itemId":"i1","seq":\#(seq)}}"#,
                providerEvent: nil
            )
        }
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: ordinary,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.durableHostMetadataDecodeCountForTesting,
            0,
            "a full ordinary stream flush must perform no host-attestation JSON decodes"
        )

        let proof = AssistantItemHostAttestation(
            itemType: .tool,
            body: AssistantContentFingerprint(
                byteCount: 4,
                sha256: Data(repeating: 1, count: 32)
            ),
            output: nil
        )
        let hostEvent = AssistantEvent.itemHostMetadata(
            turnId: "turn",
            itemId: "item",
            distillApplied: true,
            attestation: proof
        )
        let canonical = String(decoding: try JSONEncoder().encode(hostEvent), as: UTF8.self)
        let escaped = canonical.replacingOccurrences(
            of: #""itemHostMetadata""#,
            with: #""\u0069temHostMetadata""#
        )
        XCTAssertNotEqual(escaped, canonical, "fixture must exercise the escaped-key fallback")
        try runs.appendStreamEvent(
            runId: run.id,
            seq: 17,
            kind: "unexpected-but-payload-authoritative",
            payloadJSON: escaped
        )
        XCTAssertEqual(runs.durableHostMetadataDecodeCountForTesting, 1)

        let count = try db.prepare(
            "SELECT COUNT(*) FROM agent_item_host_attestations WHERE run_id = ? AND seq = 17;"
        )
        try count.bind(1, run.id.value.uuidString)
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(0), 1,
                       "escaped valid host metadata must retain its durable identity")
    }

    func test_persistStreamBatch_skipsReversibleStoreWhenUnderLimit() throws {
        // WHY: persistStreamBatch and boundPayloadForPersistence constructed
        // ReversibleContentStore on every token-sized row even though
        // softTruncate returns identity under the 16 MiB ceiling. Store-before-loss
        // only runs when the payload exceeds the limit.
        let tmp = NSTemporaryDirectory() + "RC2ReversibleStoreSkip-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "store-skip", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)

        let items = (1...16).map { seq in
            AgentRunRepository.StreamWriteIntent(
                seq: seq,
                kind: "itemDelta(i1)",
                payloadJSON: #"{"itemDelta":{"itemId":"i1","seq":\#(seq)}}"#,
                providerEvent: ProviderRuntimeEvent(
                    id: "evt-\(seq)",
                    provider: .codex,
                    source: "test",
                    method: "event",
                    payloadJSON: #"{"i":\#(seq)}"#,
                    receivedAtMs: Int64(seq)
                )
            )
        }
        XCTAssertEqual(runs.reversibleStoreInitCountForTesting, 0)
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: items,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.reversibleStoreInitCountForTesting, 0,
            "16 under-limit stream+provider rows must not construct ReversibleContentStore"
        )
        XCTAssertEqual(try runs.maxStreamEventSeq(runId: run.id), 16)

        let oversized = String(repeating: "a", count: 64)
        _ = try runs.boundPayloadForPersistence(oversized, byteLimit: 8)
        XCTAssertEqual(
            runs.reversibleStoreInitCountForTesting, 1,
            "a payload over the caller limit must still construct the store"
        )
    }

    func test_persistStreamBatch_skipsIdentitySelectOnFirstWriteOfNewSeqs() throws {
        // WHY: persistStreamBatch used to SELECT event_kind+payload_json for
        // every (run_id, seq) before INSERT (~16 probes / 250ms flush) even
        // when the coordinator had just allocated those sequences. First write
        // of a seq above the durable high-water mark can INSERT; retry and a
        // fresh repository instance must still probe so matching bytes stay
        // idempotent and a different identity still fails loud.
        let tmp = NSTemporaryDirectory() + "RC2StreamIdentitySelect-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "stream-select", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)

        func intent(seq: Int, kind: String = "itemDelta(i1)") -> AgentRunRepository.StreamWriteIntent {
            AgentRunRepository.StreamWriteIntent(
                seq: seq,
                kind: kind,
                payloadJSON: #"{"itemDelta":{"itemId":"i1","seq":\#(seq)}}"#,
                providerEvent: nil
            )
        }

        let firstFlush = (1...16).map { intent(seq: $0) }
        XCTAssertEqual(runs.streamEventIdentitySelectCountForTesting, 0)
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: firstFlush,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.streamEventIdentitySelectCountForTesting, 0,
            "first write of seqs 1...16 must INSERT without an identity SELECT"
        )
        XCTAssertEqual(try runs.maxStreamEventSeq(runId: run.id), 16)

        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: firstFlush,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.streamEventIdentitySelectCountForTesting, 16,
            "retry of the same prefix must SELECT each identity instead of inserting a second row"
        )
        XCTAssertEqual(try runs.maxStreamEventSeq(runId: run.id), 16)

        let secondFlush = (17...32).map { intent(seq: $0) }
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: secondFlush,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.streamEventIdentitySelectCountForTesting, 16,
            "seqs above the committed high-water mark must not SELECT again"
        )
        XCTAssertEqual(try runs.maxStreamEventSeq(runId: run.id), 32)

        let fresh = AgentRunRepository(db: db)
        try fresh.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: [intent(seq: 32)],
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            fresh.streamEventIdentitySelectCountForTesting, 1,
            "a new repository instance must seed from durable MAX and probe a retry"
        )
        XCTAssertEqual(try fresh.maxStreamEventSeq(runId: run.id), 32)

        XCTAssertThrowsError(
            try fresh.persistStreamBatch(
                runId: run.id,
                threadId: thread.id,
                items: [intent(seq: 32, kind: "turnStarted(t1)")],
                shouldPruneStreamEvents: false
            )
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("Conflicting stream event identity"),
                "retry with a different kind must still fail loud: \(text)"
            )
        }
    }

    func test_persistStreamBatch_durableHostIdentityFencesPrunedSequenceRetries() throws {
        // WHY: retention may remove the rolling row while its host proof stays.
        // A retry must accept the exact committed bytes but reject any different
        // event that attempts to reuse that durable raw occurrence.
        let tmp = NSTemporaryDirectory() + "RC2DurableHostIdentity-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "durable identity", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)
        let proof = AssistantItemHostAttestation(
            itemType: .tool,
            body: AssistantContentFingerprint(
                byteCount: 4,
                sha256: Data(repeating: 1, count: 32)
            ),
            output: nil
        )
        let event = AssistantEvent.itemHostMetadata(
            turnId: "turn",
            itemId: "item",
            distillApplied: true,
            attestation: proof
        )
        let exact = AgentRunRepository.StreamWriteIntent(
            seq: 1,
            kind: event.debugDescription,
            payloadJSON: String(decoding: try JSONEncoder().encode(event), as: UTF8.self),
            providerEvent: nil
        )
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: [exact],
            shouldPruneStreamEvents: false
        )
        let deleteRolling = try db.prepare(
            "DELETE FROM agent_stream_events WHERE run_id = ? AND seq = 1;"
        )
        try deleteRolling.bind(1, run.id.value.uuidString)
        _ = try deleteRolling.step()

        let fresh = AgentRunRepository(db: db)
        try fresh.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: [exact],
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(try fresh.countStreamEvents(threadId: thread.id), 0,
                       "an exact retry must use durable identity without resurrecting a pruned row")
        XCTAssertEqual(
            try fresh.listLatestStreamEvents(threadId: thread.id, strictDecoding: true),
            [event]
        )

        let conflicting = AssistantEvent.turnStarted(turnId: "different")
        XCTAssertThrowsError(try fresh.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: [AgentRunRepository.StreamWriteIntent(
                seq: 1,
                kind: conflicting.debugDescription,
                payloadJSON: String(decoding: try JSONEncoder().encode(conflicting), as: UTF8.self),
                providerEvent: nil
            )],
            shouldPruneStreamEvents: false
        )) { error in
            XCTAssertTrue(String(describing: error).contains("Conflicting durable stream event identity"))
        }
        XCTAssertEqual(try fresh.countStreamEvents(threadId: thread.id), 0,
                       "the conflicting retry transaction must not insert a replacement")
    }

    func test_persistStreamBatch_skipsProviderIdentitySelectOnFirstWrite() throws {
        // WHY: persistStreamBatch used to SELECT the full provider-log row
        // (payload_json included) before every INSERT even when the
        // coordinator had just minted a new event_id. Claude SDK lines emit
        // a providerRuntime pair at token rate. First write of an unseen id
        // can INSERT; retry and a new repository instance must still probe.
        let tmp = NSTemporaryDirectory() + "RC2ProviderIdentitySelect-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "provider-select", provider: .claude, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .claude, model: "m")
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)

        func intent(seq: Int, eventId: String, method: String = "content_block_delta") -> AgentRunRepository.StreamWriteIntent {
            AgentRunRepository.StreamWriteIntent(
                seq: seq,
                kind: "providerRuntime(\(eventId))",
                payloadJSON: #"{"providerRuntime":{"id":"\#(eventId)"}}"#,
                providerEvent: ProviderRuntimeEvent(
                    id: eventId,
                    provider: .claude,
                    source: "claude.agent-sdk",
                    method: method,
                    payloadJSON: #"{"type":"\#(method)","id":"\#(eventId)"}"#,
                    receivedAtMs: Int64(seq)
                )
            )
        }

        let firstIds = (1...16).map { "evt-\($0)" }
        let firstFlush = zip(1...16, firstIds).map { intent(seq: $0, eventId: $1) }
        XCTAssertEqual(runs.providerEventIdentitySelectCountForTesting, 0)
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: firstFlush,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.providerEventIdentitySelectCountForTesting, 0,
            "first write of 16 new provider event_ids must INSERT without an identity SELECT"
        )
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 16)

        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: firstFlush,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.providerEventIdentitySelectCountForTesting, 16,
            "retry of the same provider ids must SELECT each identity instead of inserting a second row"
        )
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 16)

        let secondIds = (17...32).map { "evt-\($0)" }
        let secondFlush = zip(17...32, secondIds).map { intent(seq: $0, eventId: $1) }
        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: secondFlush,
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            runs.providerEventIdentitySelectCountForTesting, 16,
            "new provider event_ids above the seeded set must not SELECT again"
        )
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 32)

        let fresh = AgentRunRepository(db: db)
        try fresh.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: [intent(seq: 32, eventId: "evt-32")],
            shouldPruneStreamEvents: false
        )
        XCTAssertEqual(
            fresh.providerEventIdentitySelectCountForTesting, 1,
            "a new repository instance must seed durable event_ids and probe a retry"
        )
        XCTAssertEqual(try fresh.countProviderEventLogs(threadId: thread.id), 32)

        XCTAssertThrowsError(
            try fresh.persistStreamBatch(
                runId: run.id,
                threadId: thread.id,
                items: [intent(seq: 32, eventId: "evt-32", method: "message_stop")],
                shouldPruneStreamEvents: false
            )
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("Conflicting provider event identity"),
                "retry with a different method must still fail loud: \(text)"
            )
        }
        XCTAssertEqual(try fresh.countProviderEventLogs(threadId: thread.id), 32)
    }

    func test_streamEventReplayLimitKeepsNewestEventsInChronologicalOrder() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "bounded history", provider: .codex, model: "m")
        try threads.upsert(thread)

        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .completed, startedAt: Date(timeIntervalSince1970: 1))
        try runs.upsert(run)
        for index in 0..<650 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }

        let replayed = try runs.listLatestStreamEvents(threadId: thread.id, limit: 500)

        XCTAssertEqual(replayed.count, AgentEventRetentionPolicy.production.streamEventCountPerThread)
        XCTAssertEqual(replayed.first, .turnStarted(turnId: "turn-550"),
                       "long Agent App reload must drop the oldest persisted provider events, not the newest output")
        XCTAssertEqual(replayed.last, .turnStarted(turnId: "turn-649"),
                       "bounded replay must keep the newest provider event visible after restart")
    }

    func test_streamEventPruneKeepsNewestEventsAcrossRuns() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "retention", provider: .codex, model: "m")
        try threads.upsert(thread)

        let firstRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .completed, startedAt: Date(timeIntervalSince1970: 1))
        let secondRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .completed, startedAt: Date(timeIntervalSince1970: 2))
        try runs.upsert(firstRun)
        try runs.upsert(secondRun)
        for index in 0..<8 {
            try runs.appendStreamEvent(
                runId: firstRun.id,
                seq: index + 1,
                kind: "turnStarted(first-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"first-\#(index)"}}"#
            )
        }
        for index in 0..<8 {
            try runs.appendStreamEvent(
                runId: secondRun.id,
                seq: index + 1,
                kind: "turnStarted(second-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"second-\#(index)"}}"#
            )
        }

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 10)
        let replayed = try runs.listLatestStreamEvents(threadId: thread.id, limit: 20)

        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 10,
                       "long provider streams must not grow persisted event rows without a retention cap")
        XCTAssertEqual(replayed.first, .turnStarted(turnId: "first-6"),
                       "retention pruning must remove oldest events across runs, not only trim the latest run")
        XCTAssertEqual(replayed.last, .turnStarted(turnId: "second-7"),
                       "retention pruning must keep newest provider output for restart replay")
    }

    func test_providerEventLogSurvivesBoundedStreamEventPruning() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "provider logs", provider: .codex, model: "m")
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .completed, startedAt: Date(timeIntervalSince1970: 1))
        try threads.upsert(thread)
        try runs.upsert(run)

        for index in 0..<20 {
            let runtime = ProviderRuntimeEvent(
                id: "runtime-\(index)",
                provider: .codex,
                source: "codex.app-server",
                method: "item/completed",
                providerTurnId: "turn-\(index)",
                providerItemId: "item-\(index)",
                providerRequestId: nil,
                payloadJSON: #"{"type":"item/completed","index":\#(index)}"#,
                receivedAtMs: Int64(index)
            )
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "providerRuntime(\(runtime.method))",
                payloadJSON: String(data: try JSONEncoder().encode(AssistantEvent.providerRuntime(runtime)), encoding: .utf8)!
            )
            try runs.appendProviderEventLog(threadId: thread.id, runId: run.id, event: runtime)
        }

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 5)

        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 5,
                       "UI replay stream events should stay bounded for long Agent App sessions")
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 20,
                       "native provider event logs must survive stream replay pruning so transport diagnostics are not lost")
        let latest = try runs.listLatestProviderEventLogs(threadId: thread.id, limit: 3)
        XCTAssertEqual(latest.map(\.id), ["runtime-17", "runtime-18", "runtime-19"])
        XCTAssertEqual(latest.last?.providerItemId, "item-19",
                       "provider log replay must retain native item/request refs for later debugging")
    }

    func test_providerEventLogCorruptionFailsLoudInsteadOfSkippingNativeEvidence() throws {
        let tmp = NSTemporaryDirectory() + "RC2ProviderLogCorrupt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "provider logs corrupt", provider: .codex, model: "m")
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try threads.upsert(thread)
        try runs.upsert(run)
        try runs.appendProviderEventLog(threadId: thread.id, runId: run.id, event: ProviderRuntimeEvent(
            id: "runtime-corrupt",
            provider: .codex,
            source: "codex.app-server",
            method: "item/completed",
            providerTurnId: "turn-corrupt",
            providerItemId: "item-corrupt",
            providerRequestId: nil,
            payloadJSON: #"{"type":"item/completed"}"#,
            receivedAtMs: 1
        ))
        try db.execute("UPDATE agent_provider_event_logs SET provider = 'unknown-provider' WHERE event_id = 'runtime-corrupt';")

        XCTAssertThrowsError(try runs.listLatestProviderEventLogs(threadId: thread.id),
                             "corrupt provider event rows must fail loud instead of skipping native evidence during long-run diagnostics") { error in
            XCTAssertTrue(String(describing: error).contains("Corrupt provider event log"))
        }
    }

    func test_terminalOutputHistoryReadsBoundedOlderWindows() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = UUID().uuidString

        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 1, data: Data("older-".utf8))
        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 2, data: Data("middle-".utf8))
        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 3, data: Data("newest".utf8))

        let latest = try repo.readWindow(surfaceID: surfaceID, maxBytes: 14)

        XCTAssertEqual(latest.text, "middle-newest",
                       "terminal history fetch must return newest DB chunks without loading the whole scrollback into memory")
        XCTAssertTrue(latest.hasMoreOlder, "bounded history windows must expose an older-page cursor for infinite scroll")
        let older = try repo.readWindow(surfaceID: surfaceID, beforeChunkID: latest.nextBeforeChunkID, maxBytes: 64)
        XCTAssertEqual(older.text, "older-",
                       "fetching before the cursor must read the next older DB-backed terminal history page")
        XCTAssertFalse(older.hasMoreOlder)
    }

    // The history cap must allow more than 20 entries so older prompts are not
    // silently lost when the user types more than 20 commands in a session.
    func test_promptHistoryStore_capAllowsMoreThan20Entries() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        let entries = (1...25).map { "cmd-\($0)" }
        store.save(entries, workspaceID: ws)

        let loaded = store.load(workspaceID: ws)
        XCTAssertEqual(loaded.count, 25,
                       "raising the cap beyond 20 must allow all 25 entries to survive a save/load round-trip; a 20-cap makes older prompts unrecoverable")
        XCTAssertEqual(loaded.last, "cmd-25",
                       "most recent entry must appear last (append order) after load")
        XCTAssertTrue(PromptHistoryStore.limit > 20,
                      "static limit must be greater than 20 so up-arrow recall is not silently truncated")
    }

    // search must return entries matching the query (case-insensitive), exclude
    // non-matches, respect the result limit, and return most-recent-first.
    func test_promptHistoryStore_search_filtersCaseInsensitiveAndMostRecentFirst() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        // Save in chronological order (oldest first); load returns same order.
        store.save([
            "swift build",
            "swift test",
            "git status",
            "Swift Package Show Dependencies",
            "git log --oneline"
        ], workspaceID: ws)

        // Case-insensitive match: "swift" should hit entries 1, 2, 4 (most-recent-first).
        let matches = store.search(workspaceID: ws, query: "swift")
        XCTAssertEqual(matches, [
            "Swift Package Show Dependencies",
            "swift test",
            "swift build"
        ], "search must return matching entries most-recent-first so the most useful history is surfaced first; a missing search makes older prompts unrecoverable")

        // Non-matching query returns empty.
        let none = store.search(workspaceID: ws, query: "docker")
        XCTAssertTrue(none.isEmpty,
                      "search must exclude entries that do not contain the query string")

        // Limit is respected.
        let limited = store.search(workspaceID: ws, query: "swift", limit: 2)
        XCTAssertEqual(limited.count, 2,
                       "search limit must cap the result set so callers can control result list size")
        XCTAssertEqual(limited.first, "Swift Package Show Dependencies",
                       "search with limit must still return most-recent entries first")
    }

    // search must be scoped per-workspace: entries from another workspace must
    // not appear in results.
    func test_promptHistoryStore_search_isScopedToWorkspace() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let wsA = WorkspaceID()
        let wsB = WorkspaceID()

        store.save(["swift build", "swift test"], workspaceID: wsA)
        store.save(["git status"], workspaceID: wsB)

        let resultsA = store.search(workspaceID: wsA, query: "swift")
        let resultsB = store.search(workspaceID: wsB, query: "swift")

        XCTAssertEqual(resultsA.count, 2,
                       "search must return matching entries scoped to the requested workspace")
        XCTAssertTrue(resultsB.isEmpty,
                      "search must not leak entries across workspace boundaries")
    }

    // search on empty history must return empty without crashing.
    func test_promptHistoryStore_search_emptyHistoryReturnsEmpty() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        XCTAssertTrue(store.search(workspaceID: ws, query: "anything").isEmpty,
                      "search on a workspace with no history must return empty without crashing")
    }

    // search deduplicates: if the same command appears multiple times only the
    // most-recent occurrence should be returned.
    func test_promptHistoryStore_search_deduplicatesEntries() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        store.save(["swift build", "git status", "swift build", "swift build"], workspaceID: ws)

        let matches = store.search(workspaceID: ws, query: "swift build")
        XCTAssertEqual(matches, ["swift build"],
                       "search must deduplicate repeated prompts so the history list is not cluttered with identical entries")
    }

    // Closing a workspace must delete its prompt history so user-typed prompts do
    // not leak on disk indefinitely (privacy + unbounded settings-table growth).
    func test_promptHistoryStore_deleteWorkspace_removesItsHistoryAndPreservesOthers() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)

        let wsA = WorkspaceID()
        let wsB = WorkspaceID()

        store.save(["cmd-a1", "cmd-a2"], workspaceID: wsA)
        store.save(["cmd-b1"], workspaceID: wsB)

        // Precondition: both workspaces have history.
        XCTAssertEqual(store.load(workspaceID: wsA), ["cmd-a1", "cmd-a2"])
        XCTAssertEqual(store.load(workspaceID: wsB), ["cmd-b1"])

        // Simulate workspace A being closed/removed.
        try store.delete(workspaceID: wsA)

        // Post-condition: A's history is gone; B's is untouched.
        XCTAssertTrue(store.load(workspaceID: wsA).isEmpty,
                      "closing a workspace must purge its prompt history from the settings table")
        XCTAssertEqual(store.load(workspaceID: wsB), ["cmd-b1"],
                       "deleting one workspace's prompt history must not affect other workspaces")
    }
}
