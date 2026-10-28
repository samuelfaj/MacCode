import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

final class BotContextGuestResourcesTests: XCTestCase {
    private final class CountingSecrets: BotSecretStore, @unchecked Sendable {
        private let backing = InMemoryBotSecretStore()
        private let lock = NSLock()
        private(set) var reads = 0

        func list(botID: BotID) throws -> [BotSecretMetadata] {
            lock.lock(); reads += 1; lock.unlock()
            return try backing.list(botID: botID)
        }
        func save(botID: BotID, name: String, value: String) throws { try backing.save(botID: botID, name: name, value: value) }
        func load(botID: BotID, name: String) throws -> String? {
            lock.lock(); reads += 1; lock.unlock()
            return try backing.load(botID: botID, name: name)
        }
        func delete(botID: BotID, name: String) throws { try backing.delete(botID: botID, name: name) }
        func deleteAll(botID: BotID) throws { try backing.deleteAll(botID: botID) }
    }

    private func fixture() throws -> (URL, BotStore, AgentThreadRepository, Workspace, AgentThread, BotContext, String, Int64) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BotContextGuestResources-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("bots.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Context bot", title: "Context", description: "", handle: "context-bot", soul: "", provider: .claude, model: "opus")
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = Workspace.empty(name: "Workspace", cwd: workspaceDir.path)
        let host = "trusted-host"
        let context = BotContext.workspace(workspace.id)
        let grant = try store.grantContext(hostID: host, botID: bot.id, context: context, actions: [.read, .send, .configure, .files], expectedRevision: nil)
        let thread = AgentThread(workspaceId: workspace.id, title: "Pinned", provider: .distill, model: "distill")
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
        _ = try store.createContextualConversation(conversation, newThread: thread, hostID: host, context: context, policyRevision: grant.policyRevision)
        let repository = AgentThreadRepository(db: db)
        return (root, store, repository, workspace, try XCTUnwrap(repository.get(id: thread.id)), context, host, grant.policyRevision)
    }

    private func assertRejected(root: URL, store: BotStore, repo: AgentThreadRepository, workspace: Workspace, thread: AgentThread, host: String, secrets: CountingSecrets) {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let service = BotComputerGuestService(appSupport: support, docker: BotComputerDockerCLI(), observeAttempts: 1, observeDelay: 0)
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: "distill", cwd: workspace.cwd, prompt: "test")
        XCTAssertThrowsError(try BotContextGuestResources.prepare(request: request, hostID: host, store: store, threadRepo: repo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: secrets))
        XCTAssertEqual(secrets.reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeRoot(appSupport: support).path))
    }

    func testWrongTrustedHostRejectedBeforeSecretReadOrHomeCreation() throws {
        let (root, store, repo, workspace, thread, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = CountingSecrets()
        assertRejected(root: root, store: store, repo: repo, workspace: workspace, thread: thread, host: "wrong-host", secrets: secrets)
    }

    func testLateCancelOfFinishedRuntimeCannotStopNewOwner() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real Docker runtime ownership probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching existing Docker r8 image required; probe never builds an image")
        }

        let (root, store, repo, workspace, thread, _, host, _) = try fixture()
        let support = root.appendingPathComponent("support", isDirectory: true)
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        let botID: BotID
        guard case .bot(let id) = thread.actor else { throw XCTSkip("fixture thread must belong to a bot") }
        botID = id
        let binding = try XCTUnwrap(store.getContextBinding(hostID: host, botID: botID, context: .workspace(workspace.id)))
        let identity = try BotContextRuntimeIdentity(binding: binding)
        let container = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
        defer {
            do {
                try service.wipe(identity: identity)
                XCTAssertFalse(try docker.containerExists(name: container))
                XCTAssertFalse(try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID)))
                try FileManager.default.removeItem(at: root)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            } catch {
                XCTFail("fixture cleanup failed: \(error)")
            }
        }

        let firstRequest = AgentRunRequest(runId: AgentRunID(), threadId: thread.id, provider: .distill, model: "distill", cwd: workspace.cwd, prompt: "test")
        let first = try BotContextGuestResources.prepare(request: firstRequest, hostID: host, store: store, threadRepo: repo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: nil)
        XCTAssertNil(first.envFileURL)
        XCTAssertNil(first.configDirectory)
        XCTAssertEqual(first.identity, identity)
        try first.finish()

        let secondRequest = AgentRunRequest(runId: AgentRunID(), threadId: thread.id, provider: .distill, model: "distill", cwd: workspace.cwd, prompt: "test")
        let second = try BotContextGuestResources.prepare(request: secondRequest, hostID: host, store: store, threadRepo: repo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: nil)
        XCTAssertEqual(second.identity, first.identity)
        XCTAssertEqual(second.container, first.container)
        XCTAssertNotEqual(second.runID, first.runID)
        XCTAssertTrue(try docker.inspect(name: second.container).running)
        try first.cancel()
        XCTAssertTrue(try docker.containerExists(name: second.container), "late cancel must not remove newer owner's container")
        XCTAssertTrue(try docker.inspect(name: second.container).running, "late cancel must not stop newer owner's runtime")
        try second.cancel()
        XCTAssertFalse(try docker.inspect(name: second.container).running)

        // WHY: two live conversations share the VM; stopping one must not
        // stop the container under the other, and the last one stops it.
        let a = try BotContextGuestResources.prepare(request: AgentRunRequest(runId: AgentRunID(), threadId: thread.id, provider: .distill, model: "distill", cwd: workspace.cwd, prompt: "a"), hostID: host, store: store, threadRepo: repo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: nil)
        let b = try BotContextGuestResources.prepare(request: AgentRunRequest(runId: AgentRunID(), threadId: thread.id, provider: .distill, model: "distill", cwd: workspace.cwd, prompt: "b"), hostID: host, store: store, threadRepo: repo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: nil)
        XCTAssertEqual(a.container, b.container)
        try a.cancel()
        XCTAssertTrue(try docker.inspect(name: b.container).running, "stopping A must keep the VM running for B")
        try b.cancel()
        XCTAssertFalse(try docker.inspect(name: b.container).running, "the last run stops the VM")
    }

    func testPersistedRunAsUserRejectedWhenRequestOmitsIt() throws {
        let (root, store, repo, workspace, original, _, host, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = AgentRunAsUser(generatedUID: "other-user", shortName: "other", uid: getuid() + 1, gid: getgid(), homePath: "/Users/other")
        var thread = original
        thread.runAsUser = user
        try repo.upsert(thread)
        XCTAssertEqual(try repo.get(id: thread.id)?.runAsUser, user)
        let secrets = CountingSecrets()
        assertRejected(root: root, store: store, repo: repo, workspace: workspace, thread: thread, host: host, secrets: secrets)
    }
}

