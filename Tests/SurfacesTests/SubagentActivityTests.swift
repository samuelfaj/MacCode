import XCTest
@testable import Surfaces
import CoreModel
import AgentRuntime

/// WHY: Subagents UI must project real admission-receipt lifecycle for every
/// provider without inventing success, zeros, or provider-specific layout rules.
/// These pure tests lock mapping, normalization, bounds, duration, and empty/unknown
/// handling so the badge cannot lie when receipts or coordinator state are partial.
final class SubagentActivityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threadA = AgentThreadID()
    private let threadB = AgentThreadID()

    // MARK: - Lifecycle → phase / active

    func test_mapPhase_acceptedIsWorking_notCompleted() {
        // WHY: an admitted-but-not-finalized receipt is still in flight; showing
        // Done would claim terminal success the ledger has not recorded.
        let receipt = makeReceipt(lifecycle: .accepted, finalStatus: nil)
        XCTAssertEqual(
            SubagentActivityProjection.mapPhase(receipt: receipt),
            .working,
            "accepted lifecycle must map to Working so Active never under-counts live work"
        )
        XCTAssertTrue(
            SubagentActivityProjection.isActiveReceipt(receipt: receipt),
            "accepted receipts belong in Active until finalized"
        )
    }

    func test_mapPhase_finalizedStatusesStayDistinct() {
        // WHY: completed/failed/cancelled must remain distinguishable; collapsing
        // them into a single "done" phase hides failures from the operator.
        XCTAssertEqual(
            SubagentActivityProjection.mapFinalPhase(.completed),
            .completed
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapFinalPhase(.failed),
            .failed
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapFinalPhase(.cancelled),
            .cancelled
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapFinalPhase(.interrupted),
            .cancelled,
            "interrupted is a non-success terminal outcome, not completed"
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapFinalPhase(nil),
            .unknown,
            "finalized without finalRunStatus must not invent completed"
        )
    }

    func test_mapPhase_unknownWithoutActiveRunStaysUnknown() {
        // WHY: reconcile marks uncertainty as unknown; treating that as Done/success
        // would hide lost ownership. Without coordinator activity it is not Active.
        let runId = AgentRunID()
        let receipt = makeReceipt(
            lifecycle: .unknown,
            finalStatus: nil,
            runId: runId
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapPhase(receipt: receipt, activeRunIds: []),
            .unknown
        )
        XCTAssertFalse(
            SubagentActivityProjection.isActiveReceipt(receipt: receipt, activeRunIds: [])
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapPhase(receipt: receipt, activeRunIds: [runId]),
            .working,
            "coordinator still owns the run → surface Working until finalized"
        )
        XCTAssertTrue(
            SubagentActivityProjection.isActiveReceipt(receipt: receipt, activeRunIds: [runId])
        )

        let staleExternal = makeReceipt(
            lifecycle: .unknown,
            finalStatus: nil,
            runId: runId,
            decisionReason: "external-controlled-child"
        )
        XCTAssertEqual(
            SubagentActivityProjection.mapPhase(
                receipt: staleExternal,
                activeRunIds: [runId]
            ),
            .unknown,
            "a coordinator projection must not revive an external receipt whose lease/PID reconciliation failed"
        )
        XCTAssertFalse(
            SubagentActivityProjection.isActiveReceipt(
                receipt: staleExternal,
                activeRunIds: [runId]
            )
        )
    }

    // MARK: - Provider normalization

    func test_normalizeProvider_mapsCodexClaudeGrokAndLeavesNoImplicitDefault() {
        // WHY: the surface must support all three hosts through one model; a
        // silent default would mis-color Grok as Codex and break multi-provider parity.
        XCTAssertEqual(SubagentActivityProjection.normalizeProvider(.codex), .codex)
        XCTAssertEqual(SubagentActivityProjection.normalizeProvider(.claude), .claude)
        XCTAssertEqual(SubagentActivityProjection.normalizeProvider(.grok), .grok)
        XCTAssertEqual(
            Set(AgentProvider.allCases.map(SubagentActivityProjection.normalizeProvider)),
            Set(SubagentProviderKind.allCases.filter { $0 != .unknown }),
            "every AgentProvider case must normalize to a non-unknown kind"
        )
    }

    func test_normalizeModel_emptyAndUnknownBecomeNil() {
        // WHY: blank/unknown model must render as null, never as the literal
        // string "unknown" that looks like a real model id.
        XCTAssertNil(SubagentActivityProjection.normalizeModel(""))
        XCTAssertNil(SubagentActivityProjection.normalizeModel("   "))
        XCTAssertNil(SubagentActivityProjection.normalizeModel("unknown"))
        XCTAssertNil(SubagentActivityProjection.normalizeModel("Unknown"))
        XCTAssertEqual(SubagentActivityProjection.normalizeModel("gpt-5.6"), "gpt-5.6")
    }

    // MARK: - Display name from nodeId

    func test_displayName_usesKindProviderAndLastFour() {
        // WHY: list rows should scan as Nested/Native + host + short id — not a
        // wall of pid/hex from the raw nodeId.
        XCTAssertEqual(
            SubagentActivityProjection.displayName(
                nodeId: "nested.claude.74435.28b8e3e249e9c",
                provider: .claude
            ),
            "Nested - Claude - 9e9c"
        )
        XCTAssertEqual(
            SubagentActivityProjection.displayName(
                nodeId: "native.grok.019fb358-e6dd-7842-b527-abcdef12e8a6",
                provider: .grok
            ),
            "Native - Grok - e8a6"
        )
        XCTAssertEqual(
            SubagentActivityProjection.displayName(nodeId: "deep-worker-plan-writer", provider: .codex),
            "Worker - Codex - iter",
            "non-prefixed workers still get a bounded Worker label + tail"
        )
        XCTAssertEqual(
            SubagentActivityProjection.displayName(nodeId: "unknown"),
            "Unknown"
        )
        XCTAssertEqual(
            SubagentActivityProjection.displayName(nodeId: "  "),
            "Unknown"
        )
        XCTAssertEqual(
            SubagentActivityProjection.displayName(
                nodeId: "root",
                provider: .claude,
                model: "opus"
            ),
            "opus",
            "root admissions prefer model over a fake worker title"
        )
        XCTAssertEqual(
            SubagentActivityProjection.displayName(nodeId: "root", provider: .codex, model: nil),
            "Root - Codex"
        )
        XCTAssertEqual(SubagentActivityProjection.kindLabel(from: "nested.claude.x"), "Nested")
        XCTAssertEqual(SubagentActivityProjection.kindLabel(from: "native.grok.x"), "Native")
        XCTAssertEqual(SubagentActivityProjection.lastFourIdentityChars(from: "a.b.c0ffee"), "ffee")
    }

    // MARK: - Sorting and bounds

    func test_project_partitionsActiveAndDone_sortsDoneNewestFirst_andBoundsCompleted() {
        // WHY: Done must be newest-first and capped so a long-lived workspace cannot
        // ship unbounded history into the popover / main-thread layout.
        let olderDone = makeReceipt(
            id: UUID(),
            lifecycle: .finalized,
            finalStatus: .completed,
            admittedAt: now.addingTimeInterval(-20_000),
            lifecycleUpdatedAt: now.addingTimeInterval(-20_000),
            finalizedAt: now.addingTimeInterval(-20_000),
            nodeId: "older-done",
            provider: .codex
        )
        let newerDone = makeReceipt(
            id: UUID(),
            lifecycle: .finalized,
            finalStatus: .failed,
            admittedAt: now.addingTimeInterval(-600),
            lifecycleUpdatedAt: now.addingTimeInterval(-100),
            finalizedAt: now.addingTimeInterval(-100),
            nodeId: "newer-done",
            provider: .grok
        )
        let active = makeReceipt(
            id: UUID(),
            lifecycle: .accepted,
            finalStatus: nil,
            admittedAt: now.addingTimeInterval(-50),
            lifecycleUpdatedAt: now.addingTimeInterval(-10),
            nodeId: "live-worker",
            provider: .claude
        )
        let extraDone: [AgentOrchestrationAdmissionReceipt] = (0..<5).map { i -> AgentOrchestrationAdmissionReceipt in
            let offset = TimeInterval(-10_000 - i)
            let updatedOffset = TimeInterval(-9_000 - i)
            return makeReceipt(
                id: UUID(),
                lifecycle: .finalized,
                finalStatus: .completed,
                admittedAt: now.addingTimeInterval(offset),
                lifecycleUpdatedAt: now.addingTimeInterval(updatedOffset),
                finalizedAt: now.addingTimeInterval(updatedOffset),
                nodeId: "extra-\(i)",
                provider: .codex
            )
        }

        let snapshot = SubagentActivityProjection.project(
            receipts: [olderDone, newerDone, active] + extraDone,
            activeVisibleLimit: 4,
            doneVisibleLimit: 2,
            completedBound: 3
        )

        XCTAssertEqual(snapshot.activeCount, 1, "only accepted rows are Active")
        XCTAssertEqual(snapshot.active.first?.nodeId, "live-worker")
        XCTAssertEqual(
            snapshot.doneCount,
            3,
            "completedBound must drop older Done rows so the UI stays bounded"
        )
        let doneNodeIDs = snapshot.done.map { $0.nodeId }
        XCTAssertEqual(doneNodeIDs.first, "newer-done",
                       "newest finalized receipt must lead Done")
        XCTAssertFalse(doneNodeIDs.contains("older-done"),
                       "oldest Done falls outside the bound")
        XCTAssertEqual(snapshot.hiddenDoneCount(expanded: false), 1,
                       "Show N more must report Done overflow past the visible limit")
        XCTAssertEqual(snapshot.visibleDone(expanded: false).count, 2)
        XCTAssertEqual(snapshot.visibleDone(expanded: true).count, 3,
                       "expanded Show N more reveals the full bounded Done list")
    }

    func test_project_filtersToSelectedThreadIds() {
        // WHY: the audit log is process-global; the Subagents badge is per-thread
        // chrome and must not show sibling-thread (or other workspace) admissions.
        let local = makeReceipt(
            threadId: threadA,
            lifecycle: .accepted,
            nodeId: "local-worker",
            provider: .claude
        )
        let foreign = makeReceipt(
            threadId: threadB,
            lifecycle: .finalized,
            finalStatus: .completed,
            nodeId: "foreign-worker",
            provider: .codex
        )
        let snapshot = SubagentActivityProjection.project(
            receipts: [local, foreign],
            threadIds: [threadA]
        )
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.doneCount, 0)
        XCTAssertEqual(snapshot.active.first?.threadId, threadA)
    }

    func test_project_includesParentChainDescendantsOnOtherThreads() {
        // WHY: middleware nested Agent App workers run on their own thread id but
        // must still appear on the spawning thread's badge; parent-chain is the
        // attribution link. Unrelated siblings without that chain stay excluded.
        let parentRootId = UUID()
        let parentRoot = makeReceipt(
            id: parentRootId,
            threadId: threadA,
            lifecycle: .accepted,
            nodeId: "root",
            provider: .claude
        )
        let nestedChild = makeReceipt(
            id: UUID(),
            parentReceiptId: parentRootId,
            threadId: threadB,
            lifecycle: .finalized,
            finalStatus: .completed,
            nodeId: "middleware-nested-worker",
            provider: .codex
        )
        let unrelatedSibling = makeReceipt(
            id: UUID(),
            threadId: threadB,
            lifecycle: .finalized,
            finalStatus: .completed,
            nodeId: "unrelated-sibling",
            provider: .grok
        )
        let snapshot = SubagentActivityProjection.project(
            receipts: [parentRoot, nestedChild, unrelatedSibling],
            threadIds: [threadA]
        )
        XCTAssertEqual(
            snapshot.done.map(\.nodeId),
            ["middleware-nested-worker"],
            "child receipt on a different thread whose parent is on the selected thread must be included"
        )
        XCTAssertFalse(
            snapshot.done.contains(where: { $0.nodeId == "unrelated-sibling" }),
            "sibling-thread receipts without a parent chain to the selection must stay out"
        )
        XCTAssertEqual(snapshot.activeCount, 0, "root controller is not a subagent row")
        XCTAssertTrue(
            SubagentActivityProjection.belongsToThreadScope(
                receipt: nestedChild,
                threadIds: [threadA],
                receipts: [parentRoot, nestedChild, unrelatedSibling]
            )
        )
        XCTAssertFalse(
            SubagentActivityProjection.belongsToThreadScope(
                receipt: unrelatedSibling,
                threadIds: [threadA],
                receipts: [parentRoot, nestedChild, unrelatedSibling]
            )
        )
    }

    func test_project_parentChainFailsClosedWhenAncestorMissing() {
        // WHY: if the parent fell outside the fetched activity window, inventing
        // attribution would re-open sibling leaks; fail closed instead.
        let orphanedChild = makeReceipt(
            id: UUID(),
            parentReceiptId: UUID(),
            threadId: threadB,
            lifecycle: .accepted,
            nodeId: "orphaned-nested",
            provider: .codex
        )
        let snapshot = SubagentActivityProjection.project(
            receipts: [orphanedChild],
            threadIds: [threadA]
        )
        XCTAssertTrue(snapshot.isEmpty)
    }

    func test_projectExcludesRootAndKeepsUnknownOutOfDone() {
        // WHY: the root controller is not a subagent, and an unresolved child
        // lifecycle must never inflate the Done count.
        let root = makeReceipt(
            lifecycle: .accepted,
            nodeId: "root",
            provider: .codex
        )
        let unknown = makeReceipt(
            lifecycle: .finalized,
            finalStatus: nil,
            nodeId: "worker-with-uncertain-status",
            provider: .grok
        )
        let snapshot = SubagentActivityProjection.project(receipts: [root, unknown])
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.doneCount, 0)
        XCTAssertEqual(snapshot.unknownCount, 1)
        XCTAssertEqual(snapshot.unknown.first?.nodeId, "worker-with-uncertain-status")
    }

    // MARK: - Duration

    func test_formatElapsed_andRelative_coverActiveAndDoneLabels() {
        // WHY: Active needs wall-clock duration; Done needs relative age. Wrong
        // units make long workers look idle and hide multi-day runs.
        XCTAssertEqual(SubagentActivityProjection.formatElapsedSeconds(37), "37s")
        XCTAssertEqual(SubagentActivityProjection.formatElapsedSeconds(125), "2m 5s")
        XCTAssertEqual(
            SubagentActivityProjection.formatElapsedSeconds(1_500_037),
            "17d 8h 40m 37s"
        )

        let start = now.addingTimeInterval(-90)
        XCTAssertEqual(
            SubagentActivityProjection.formatElapsed(from: start, to: now),
            "1m 30s"
        )
        XCTAssertEqual(
            SubagentActivityProjection.formatRelative(from: now.addingTimeInterval(-5), now: now),
            "just now"
        )
        XCTAssertEqual(
            SubagentActivityProjection.formatRelative(from: now.addingTimeInterval(-3_600 * 3), now: now),
            "3h ago"
        )
        XCTAssertEqual(
            SubagentActivityProjection.formatRelative(from: now.addingTimeInterval(-86_400 * 10), now: now),
            "1w ago"
        )

        let activeItem = SubagentActivityProjection.mapItem(
            receipt: makeReceipt(
                lifecycle: .accepted,
                admittedAt: now.addingTimeInterval(-45),
                nodeId: "timer"
            ),
            now: now
        )
        XCTAssertEqual(
            SubagentActivityProjection.trailingTimeLabel(for: activeItem, now: now),
            "45s",
            "active rows use elapsed duration, not relative age"
        )

        let doneItem = SubagentActivityProjection.mapItem(
            receipt: makeReceipt(
                lifecycle: .finalized,
                finalStatus: .completed,
                admittedAt: now.addingTimeInterval(-86_400 * 8),
                finalizedAt: now.addingTimeInterval(-86_400 * 7),
                nodeId: "done-timer"
            ),
            now: now
        )
        XCTAssertEqual(
            SubagentActivityProjection.trailingTimeLabel(for: doneItem, now: now),
            "1w ago",
            "done rows use relative finalization time"
        )
    }

    // MARK: - Empty / unknown data

    func test_project_emptyReceiptsYieldEmptySnapshot_notFakeCounts() {
        // WHY: zero activity must not render invented Active/Done rows or a
        // "0 done" success narrative; the badge stays empty until real receipts exist.
        let snapshot = SubagentActivityProjection.project(receipts: [])
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.doneCount, 0)
        XCTAssertFalse(snapshot.isLive)
        XCTAssertTrue(snapshot.compactGlyphProviders.isEmpty)
        XCTAssertTrue(snapshot.compactAvatarItems.isEmpty)
    }

    @MainActor
    func test_catIdentity_isStableAcrossLifecycleAndMetadataChanges() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let working = makeReceipt(id: id, lifecycle: .accepted, runId: AgentRunID(id), nodeId: "native.distill.worker", provider: .distill)
        let completed = makeReceipt(id: id, lifecycle: .finalized, finalStatus: .completed, runId: AgentRunID(id),
                                    nodeId: "nested.claude.worker", provider: .claude)
        let activeCat = SubagentActivityProjection.project(receipts: [working]).active.first!.cat
        let doneCat = SubagentActivityProjection.project(receipts: [completed]).done.first!.cat
        XCTAssertEqual(activeCat, doneCat, "completion and reopening must keep the cat's name and artwork")
        XCTAssertEqual(activeCat, SubagentCatIdentity(id: id))
        XCTAssertEqual(activeCat.name, "Chico", "UUID identities must match the iOS child-session mapping")
        XCTAssertEqual(activeCat.assetName, "cat-ginger")
        let child = SubagentActivityProjection.project(receipts: [makeReceipt(
            lifecycle: .unknown, runId: AgentRunID(id), nodeId: "native.distill.child", provider: .distill
        )]).unknown.first!
        XCTAssertEqual(child.cat, activeCat, "the child run ID is shared with iOS even when receipt IDs differ")
        XCTAssertFalse(activeCat.name.isEmpty)
        XCTAssertFalse(activeCat.breed.isEmpty)
        XCTAssertTrue(activeCat.assetName.hasPrefix("cat-"))
        XCTAssertEqual(SubagentCatIdentity.artwork.count, 6, "all generated cats must load from the resource bundle")
        XCTAssertNotNil(SubagentCatIdentity.artwork[activeCat.assetName])
        XCTAssertEqual(activeCat.shortID, "1111")
        XCTAssertNotEqual(activeCat, SubagentCatIdentity(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
    }

    func test_compactAvatarItems_prefersNewestWorkersOverProviderDedup() {
        // WHY: the chrome strip used to collapse to one glyph per provider, so
        // two Claude children looked like a single face.
        let claudeA = makeReceipt(
            id: UUID(),
            lifecycle: .accepted,
            nodeId: "nested-claude-a",
            provider: .claude
        )
        let claudeB = makeReceipt(
            id: UUID(),
            lifecycle: .finalized,
            finalStatus: .completed,
            nodeId: "nested-claude-b",
            provider: .claude
        )
        let grok = makeReceipt(
            id: UUID(),
            lifecycle: .finalized,
            finalStatus: .completed,
            nodeId: "native-grok",
            provider: .grok
        )
        let snapshot = SubagentActivityProjection.project(receipts: [claudeA, claudeB, grok])
        XCTAssertEqual(snapshot.compactAvatarItems.count, 3,
                       "strip must list each worker, not one chip per provider")
        XCTAssertEqual(
            Set(snapshot.compactAvatarItems.map(\.provider)),
            Set([.claude, .grok])
        )
    }

    func test_mapItem_unknownProviderFieldsStayExplicit() {
        // WHY: missing model / unknown lifecycle must surface as null/Unknown so
        // the UI cannot paint a green Done from incomplete ledger rows.
        let receipt = makeReceipt(
            lifecycle: .finalized,
            finalStatus: nil,
            model: "  ",
            nodeId: "unknown",
            provider: .grok
        )
        let item = SubagentActivityProjection.mapItem(receipt: receipt)
        XCTAssertEqual(item.phase, .unknown)
        XCTAssertNil(item.model)
        XCTAssertNil(item.reasoningEffort)
        XCTAssertEqual(item.displayName, "Unknown")
        XCTAssertEqual(item.statusLabel, "Unknown")
        XCTAssertFalse(item.isActive)
        XCTAssertEqual(item.provider, .grok)
    }

    func test_providerModelLabel_includesProviderModelAndReasoningEffort() {
        // WHY: operators scan subagent rows for who is running what at which
        // effort; omitting effort next to the model hides the binding that
        // actually drives cost/latency for that child.
        let withEffort = SubagentActivityProjection.mapItem(
            receipt: makeReceipt(
                lifecycle: .accepted,
                model: "grok-4.5",
                nodeId: "native.grok.019fb358-e6dd-7842-b527-abcdef12e8a6",
                provider: .grok,
                reasoningEffort: .high
            )
        )
        XCTAssertEqual(withEffort.providerModelLabel, "Grok · grok-4.5 · High")
        XCTAssertEqual(withEffort.reasoningEffort, .high)

        let withoutEffort = SubagentActivityProjection.mapItem(
            receipt: makeReceipt(
                lifecycle: .accepted,
                model: "grok-4.5",
                nodeId: "native.grok.child",
                provider: .grok,
                reasoningEffort: nil
            )
        )
        XCTAssertEqual(
            withoutEffort.providerModelLabel,
            "Grok · grok-4.5",
            "legacy receipts without effort must not invent a default effort label"
        )

        let effortOnly = SubagentActivityProjection.mapItem(
            receipt: makeReceipt(
                lifecycle: .accepted,
                model: "unknown",
                nodeId: "nested.claude.x",
                provider: .claude,
                reasoningEffort: .xhigh
            )
        )
        XCTAssertEqual(
            effortOnly.providerModelLabel,
            "Claude · Extra High",
            "when model is missing, still show provider · effort"
        )
    }

    func test_showMore_activeOverflowUsesVisibleLimit() {
        // WHY: "Show N more" is the only way to keep the popover short while
        // still proving more active workers exist; N must equal hidden count.
        let receipts = (0..<6).map { i in
            makeReceipt(
                id: UUID(),
                lifecycle: .accepted,
                admittedAt: now.addingTimeInterval(TimeInterval(-i)),
                lifecycleUpdatedAt: now.addingTimeInterval(TimeInterval(-i)),
                nodeId: "worker-\(i)",
                provider: .codex
            )
        }
        let snapshot = SubagentActivityProjection.project(
            receipts: receipts,
            activeVisibleLimit: 4,
            doneVisibleLimit: 4
        )
        XCTAssertEqual(snapshot.activeCount, 6)
        XCTAssertEqual(snapshot.visibleActive(expanded: false).count, 4)
        XCTAssertEqual(snapshot.hiddenActiveCount(expanded: false), 2)
        XCTAssertEqual(snapshot.hiddenActiveCount(expanded: true), 0)
    }

    // MARK: - Activity receipt fetch window (memory)

    func test_defaultReceiptFetchLimit_matchesRuntimeActivityWindow() {
        XCTAssertEqual(SubagentActivityProjection.defaultReceiptFetchLimit, 128)
        XCTAssertEqual(
            SubagentActivityProjection.defaultReceiptFetchLimit,
            AgentOrchestrationRuntime.defaultActivityReceiptLimit,
            "Agent App poll limit must match runtime activity default"
        )
    }

    // MARK: - Helpers

    private func makeReceipt(
        id: UUID = UUID(),
        parentReceiptId: UUID? = nil,
        threadId: AgentThreadID? = nil,
        lifecycle: AgentOrchestrationReceiptLifecycleStatus,
        finalStatus: AgentRunStatus? = nil,
        runId: AgentRunID? = AgentRunID(),
        admittedAt: Date? = nil,
        lifecycleUpdatedAt: Date? = nil,
        finalizedAt: Date? = nil,
        model: String = "model-x",
        nodeId: String = "worker",
        provider: AgentProvider = .codex,
        decisionReason: String = "test",
        reasoningEffort: AgentReasoningEffort? = nil
    ) -> AgentOrchestrationAdmissionReceipt {
        let admitted = admittedAt ?? now.addingTimeInterval(-120)
        return AgentOrchestrationAdmissionReceipt(
            id: id,
            parentReceiptId: parentReceiptId,
            runId: runId,
            threadId: threadId ?? threadA,
            nodeId: nodeId,
            attemptId: nil,
            routingRevision: 1,
            policyDigest: String(repeating: "a", count: 64),
            policyVersion: "1",
            packageRevision: "test",
            provider: provider,
            providerInstanceId: provider.rawValue,
            model: model,
            reasoningEffort: reasoningEffort,
            capabilitySnapshotId: "cap",
            decisionReason: decisionReason,
            admittedAt: admitted,
            lifecycleStatus: lifecycle,
            lifecycleUpdatedAt: lifecycleUpdatedAt ?? admitted,
            finalizedAt: finalizedAt,
            finalRunStatus: finalStatus
        )
    }
}
