import XCTest
import CoreModel
@testable import AgentRuntime
@testable import Persistence
@testable import Surfaces

/// WHY: Distill ends its turn while its subagents keep running. The Subagents
/// ledger tied a native child's life to its parent turn, so every live Distill
/// subagent showed "Unknown" the moment the turn ended, and its real end could
/// never be recorded afterwards (2026-11-17: six workers stuck "Unknown").
final class SubagentLivenessAfterTurnTests: XCTestCase {
    private var root: String!
    private var runtime: AgentOrchestrationRuntime!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "rc-native-child-liveness-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            packageVerification: { true },
            killSwitch: { false }
        )
    }

    override func tearDownWithError() throws {
        runtime.setProviderNativeChildLiveness(nil)
        try? FileManager.default.removeItem(atPath: root)
    }

    func testRunningChildOfAnEndedTurnStaysWorkingThenEndsWithTheProvidersReport() throws {
        let thread = AgentThreadID()
        let parentRun = try recordRoot(thread: thread)
        let childRun = AgentRunID()
        _ = try runtime.recordProviderNativeChild(
            runId: childRun,
            threadId: thread,
            provider: .distill,
            providerInstanceId: "distill",
            model: "unknown",
            nodeId: "native.distill.\(childRun.value.uuidString.lowercased())",
            parentRunId: parentRun
        )
        try runtime.finalizeReceipt(runId: parentRun, status: .completed)

        let provider = LivenessProbe(running: true)
        runtime.setProviderNativeChildLiveness { provider.answer(for: $0) }
        var snapshot = try badge(thread: thread)
        XCTAssertEqual(
            snapshot.active.map(\.runId), [childRun],
            "a subagent Distill still runs after its parent turn ended is Working, not Unknown"
        )
        XCTAssertEqual(snapshot.active.first?.phase, .working)
        XCTAssertTrue(snapshot.unknown.isEmpty)
        XCTAssertEqual(try receipt(childRun).lifecycleStatus, .accepted, "nothing is persisted as unknown while it runs")

        // The provider process died without a final report: uncertainty again.
        provider.running = false
        snapshot = try badge(thread: thread)
        XCTAssertEqual(snapshot.unknown.map(\.runId), [childRun], "a child no live session runs must not claim Working")

        // The next process reports what happened; that replaces the uncertainty.
        try runtime.finalizeProviderNativeChild(runId: childRun, threadId: thread, status: .cancelled)
        snapshot = try badge(thread: thread)
        XCTAssertEqual(snapshot.done.map(\.runId), [childRun])
        XCTAssertEqual(snapshot.done.first?.phase, .cancelled)
        XCTAssertTrue(snapshot.unknown.isEmpty)
    }

    func testProviderReportNeverEndsAChildThatHoldsDelegationAuthority() throws {
        // WHY: only the authenticated finalization may end an authorized nested
        // worker; a provider-native event must not be a way around it.
        let thread = AgentThreadID()
        let parentCapability = AgentDelegationCapability.issue()
        let parentRun = try recordRoot(thread: thread, capability: parentCapability)
        let childRun = AgentRunID()
        _ = try runtime.recordAuthorizedExternalChild(
            runId: childRun,
            threadId: thread,
            provider: .claude,
            providerInstanceId: "claude",
            model: "claude",
            nodeId: "native.claude.lookalike",
            parentRunId: parentRun,
            parentThreadId: thread,
            parentCapability: parentCapability,
            childCapability: AgentDelegationCapability.issue()
        )

        try runtime.finalizeProviderNativeChild(runId: childRun, threadId: thread, status: .cancelled)

        let child = try receipt(childRun)
        XCTAssertFalse(AgentOrchestrationRuntime.isProviderNativeChild(child))
        XCTAssertEqual(child.lifecycleStatus, .accepted)
        XCTAssertNil(child.finalRunStatus)
    }

    func testChildSpawnedAfterItsTurnEndedJoinsThatTurnWithoutAuthority() throws {
        // WHY: a background workflow spawns its next phase's subagents after the
        // turn that started it ended; they belong in that thread's Subagents.
        let thread = AgentThreadID()
        let parentRun = try recordRoot(thread: thread)
        try runtime.finalizeReceipt(runId: parentRun, status: .completed)
        let childRun = AgentRunID()

        let child = try XCTUnwrap(runtime.recordProviderNativeChildOfEndedTurn(
            runId: childRun,
            threadId: thread,
            provider: .distill,
            providerInstanceId: "distill",
            model: "unknown",
            nodeId: "native.distill.\(childRun.value.uuidString.lowercased())",
            parentRunId: parentRun
        ))
        XCTAssertEqual(child.parentReceiptId, try receipt(parentRun).id)
        XCTAssertEqual(child.lifecycleStatus, .accepted)
        XCTAssertNil(child.delegationCapabilitySHA256, "a provider-native child can never delegate")
        XCTAssertTrue(AgentOrchestrationRuntime.isProviderNativeChild(child))
        runtime.setProviderNativeChildLiveness { _ in true }
        XCTAssertEqual(try badge(thread: thread).active.map(\.runId), [childRun])

        let otherThreadRun = try recordRoot(thread: AgentThreadID())
        XCTAssertNil(
            try runtime.recordProviderNativeChildOfEndedTurn(
                runId: AgentRunID(),
                threadId: thread,
                provider: .distill,
                providerInstanceId: "distill",
                model: "unknown",
                nodeId: "native.distill.other",
                parentRunId: otherThreadRun
            ),
            "a child is never attributed to another thread's turn"
        )
        XCTAssertThrowsError(try runtime.recordProviderNativeChildOfEndedTurn(
            runId: AgentRunID(),
            threadId: thread,
            provider: .distill,
            providerInstanceId: "distill",
            model: "unknown",
            nodeId: "nested.claude.worker",
            parentRunId: parentRun
        ))
    }

    private func recordRoot(
        thread: AgentThreadID,
        capability: String = AgentDelegationCapability.issue()
    ) throws -> AgentRunID {
        let run = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: run,
            threadId: thread,
            provider: .distill,
            providerInstanceId: "distill",
            model: "claude/claude-opus-5-5",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(capability)
        )
        return run
    }

    /// The badge's own read path: the persisting reconciliation, then the projection.
    private func badge(thread: AgentThreadID) throws -> SubagentActivitySnapshot {
        let receipts = try runtime.activityReceipts(threadIds: [thread], persistLifecycleReconciliation: true)
        return SubagentActivityProjection.project(receipts: receipts, threadIds: [thread])
    }

    private func receipt(_ run: AgentRunID) throws -> AgentOrchestrationAdmissionReceipt {
        try XCTUnwrap(runtime.receipt(runId: run))
    }
}

private final class LivenessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(running: Bool) { value = running }
    var running: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func answer(for _: AgentOrchestrationAdmissionReceipt) -> Bool { running }
}
