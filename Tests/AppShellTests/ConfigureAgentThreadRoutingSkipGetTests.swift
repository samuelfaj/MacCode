import XCTest
@testable import AppShell
import CoreModel
import Persistence
@testable import SocketServer

/// WHY: Auto toggle / iOS routing RPC compiled the 26-column row plus routing
/// JSON twice per call.
@MainActor
final class ConfigureAgentThreadRoutingSkipGetTests: XCTestCase {
    func test_configureRouting_doesNotDurableGetAndPreservesChrome() async throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(
            title: "keep-title",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised
        )
        thread.color = "purple"
        thread.pinned = true
        thread.hasUnread = true
        thread.status = .running
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        let selection = AgentModelSelection(provider: .codex, modelId: "fake-model")
        let digest = String(repeating: "r", count: 32 * 1024)
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: selection,
            policyDigest: digest,
            revision: 1,
            updatedAt: stamped
        )
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let routingProbesBefore = ctx.threadRepo.routingConfigurationProbeCountForTesting

        let updated = try await router.configureAgentThreadRouting(
            thread: thread.id,
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: nil,
            serviceTier: nil,
            modelSelection: selection,
            providerInstanceId: nil,
            runAsUser: nil,
            routing: AgentRoutingRequest(
                mode: .manual,
                expectedRevision: 1,
                manualSelection: selection
            )
        )

        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(ctx.threadRepo.routingConfigurationProbeCountForTesting, routingProbesBefore + 1)
        XCTAssertEqual(updated.routingConfiguration?.mode, .manual)
        XCTAssertEqual(updated.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(updated.title, "keep-title")
        let stored = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.title, "keep-title")
        XCTAssertEqual(stored.color, "purple")
        XCTAssertTrue(stored.pinned)
        XCTAssertTrue(stored.hasUnread)
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
    }

    /// WHY: a phone that picks a model with a stale routing revision was told
    /// only "outcome unknown": the Mac recorded the refusal as an unknown
    /// command, so the phone could not say why the model never changed and fenced
    /// the same retry. A refusal before any write must reach the client as the
    /// real error, marked definite so the request id is freed, with the thread
    /// left exactly as it was.
    func test_staleRoutingRevisionIsADefiniteRejectionAndChangesNothing() async throws {
        let (ctx, router) = try makeRouter()
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = AgentThread(title: "t", provider: .codex, model: "fake-model", permissionMode: .supervised)
        let current = AgentModelSelection(provider: .codex, modelId: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual, manualSelection: current, policyDigest: "", revision: 2, updatedAt: stamped
        )
        try ctx.threadRepo.upsert(thread)
        let requested = AgentModelSelection(provider: .codex, modelId: "other-model")

        do {
            _ = try await router.configureAgentThreadRouting(
                thread: thread.id, provider: .codex, model: "other-model", permissionMode: nil,
                reasoningEffort: nil, serviceTier: nil, modelSelection: requested,
                providerInstanceId: nil, runAsUser: nil,
                routing: AgentRoutingRequest(mode: .manual, expectedRevision: 1, manualSelection: requested)
            )
            XCTFail("a stale revision must be refused")
        } catch let rejection as DefiniteMutationRejection {
            guard case AgentRoutingRevisionError.conflict(let expected, let actual)? =
                    rejection.underlying as? AgentRoutingRevisionError else {
                return XCTFail("the client must get the revision conflict, got \(rejection.underlying)")
            }
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(actual, 2)
        }

        let stored = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.model, "fake-model", "a refused change must not move the model")
        XCTAssertEqual(stored.routingConfiguration?.revision, 2)
    }

    /// WHY: asking a started thread for another provider is refused by the
    /// provider lock before anything is written. That refusal must reach the
    /// phone as the lock message, not as an unknown outcome.
    func test_providerLockRefusalIsADefiniteRejection() async throws {
        let (ctx, router) = try makeRouter()
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = AgentThread(title: "t", provider: .codex, model: "fake-model", permissionMode: .supervised)
        let current = AgentModelSelection(provider: .codex, modelId: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual, manualSelection: current, policyDigest: "", revision: 1, updatedAt: stamped
        )
        try ctx.threadRepo.upsert(thread)
        try ctx.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "started"))
        let other = AgentModelSelection(provider: .claude, modelId: "claude-model")

        do {
            _ = try await router.configureAgentThreadRouting(
                thread: thread.id, provider: .claude, model: "claude-model", permissionMode: nil,
                reasoningEffort: nil, serviceTier: nil, modelSelection: other,
                providerInstanceId: nil, runAsUser: nil,
                routing: AgentRoutingRequest(mode: .manual, expectedRevision: 1, manualSelection: other)
            )
            XCTFail("a started thread must refuse another provider")
        } catch let rejection as DefiniteMutationRejection {
            XCTAssertEqual((rejection.underlying as? JSONRPCError)?.code, -32010)
        }
        XCTAssertEqual(try XCTUnwrap(try ctx.threadRepo.get(id: thread.id)).provider, .codex)
    }

    private func makeRouter() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-cfg-routing-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }
}
