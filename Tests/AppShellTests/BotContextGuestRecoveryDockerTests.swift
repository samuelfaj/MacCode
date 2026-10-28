import Foundation
import Darwin
import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

final class BotContextGuestRecoveryDockerTests: XCTestCase {
    private static let rootKey = "RC_CONTEXT_RECOVERY_ROOT"
    private static let hostID = "context-recovery-subprocess"

    private struct IdentitySnapshot: Codable {
        let hostID: String
        let botID: BotID
        let context: BotContext
        let policyRevision: Int64
    }

    private struct Fixture: Codable {
        let botID: BotID
        let identities: [IdentitySnapshot]
        let workspace: Workspace
        let workspaceThreadID: AgentThreadID
        let generalThreadID: AgentThreadID
        let workspaceRunID: AgentRunID
        let generalRunID: AgentRunID
    }

    func test_childPrepareAndExit() throws {
        guard let rootPath = ProcessInfo.processInfo.environment[Self.rootKey] else {
            throw XCTSkip("child-only subprocess entry point")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("bots.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Crash probe", title: "Crash probe", description: "", handle: "crash-probe", soul: "", provider: .distill, model: "test")
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let workspace = Workspace.empty(name: "Workspace A", cwd: workspaceDirectory.path)
        let general = BotContext.general
        let workspaceContext = BotContext.workspace(workspace.id)
        let workspaceGrant = try store.grantContext(hostID: Self.hostID, botID: bot.id, context: workspaceContext, actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let generalGrant = try store.grantContext(hostID: Self.hostID, botID: bot.id, context: general, actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let workspaceThread = AgentThread(workspaceId: workspace.id, title: "A", provider: .distill, model: "test")
        let generalThread = AgentThread(workspaceId: nil, title: "B", provider: .distill, model: "test")
        _ = try store.createContextualConversation(BotConversation(botID: bot.id, title: "A", linkedAgentThreadID: workspaceThread.id), newThread: workspaceThread, hostID: Self.hostID, context: workspaceContext, policyRevision: workspaceGrant.policyRevision)
        _ = try store.createContextualConversation(BotConversation(botID: bot.id, title: "B", linkedAgentThreadID: generalThread.id), newThread: generalThread, hostID: Self.hostID, context: general, policyRevision: generalGrant.policyRevision)
        let threadRepo = AgentThreadRepository(db: db)
        let secrets = InMemoryBotSecretStore()
        try secrets.save(botID: bot.id, name: "UNSCOPED_CANARY", value: "must-not-cross-context")
        try secrets.save(botID: BotContextRuntimeIdentity(binding: workspaceGrant).storageBotID, name: "RECOVERY_CANARY", value: "workspace-secret")
        try secrets.save(botID: BotContextRuntimeIdentity(binding: generalGrant).storageBotID, name: "RECOVERY_CANARY", value: "general-secret")
        let docker = BotComputerDockerCLI()
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        let workspaceRequest = AgentRunRequest(runId: AgentRunID(), threadId: workspaceThread.id, provider: .distill, model: "test", cwd: workspace.cwd, prompt: "synthetic", environment: [:])
        let generalRequest = AgentRunRequest(runId: AgentRunID(), threadId: generalThread.id, provider: .distill, model: "test", cwd: BotHome(appSupportDirectory: support, bot: bot).root.path, prompt: "synthetic", environment: [:])
        let fixture = Fixture(botID: bot.id, identities: [
            IdentitySnapshot(hostID: Self.hostID, botID: bot.id, context: workspaceContext, policyRevision: workspaceGrant.policyRevision),
            IdentitySnapshot(hostID: Self.hostID, botID: bot.id, context: general, policyRevision: generalGrant.policyRevision),
        ], workspace: workspace, workspaceThreadID: workspaceThread.id, generalThreadID: generalThread.id, workspaceRunID: workspaceRequest.runId, generalRunID: generalRequest.runId)
        try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
        let workspaceResources = try BotContextGuestResources.prepare(request: workspaceRequest, hostID: Self.hostID, store: store, threadRepo: threadRepo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: secrets)
        let generalResources = try BotContextGuestResources.prepare(request: generalRequest, hostID: Self.hostID, store: store, threadRepo: threadRepo, service: service, appSupport: support, workspace: nil, registeredWorkspaces: [workspace.cwd], secretStore: secrets)
        let identities = [workspaceResources.identity, generalResources.identity]
        var heartbeats: [BotGuestLeaseHeartbeat] = []
        for (identity, runID) in zip(identities, [workspaceRequest.runId, generalRequest.runId]) {
            let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
            try FileManager.default.createDirectory(at: guestHome.appendingPathComponent("memory", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: guestHome.appendingPathComponent("browser", isDirectory: true), withIntermediateDirectories: true)
            try Data("memory-\(runID.value.uuidString)".utf8).write(to: guestHome.appendingPathComponent("memory/recovery-marker"))
            try Data("browser-\(runID.value.uuidString)".utf8).write(to: guestHome.appendingPathComponent("browser/recovery-marker"))
            heartbeats.append(try BotGuestLeaseHeartbeat(guestHome: guestHome, runID: runID.value.uuidString.lowercased()))
        }
        let sentinel = #"const fs=require('fs');fs.writeFileSync('/home/remotecode/.rc-recovery-sentinel.pid',String(process.pid));setInterval(()=>{},1000);"#
        for resources in [workspaceResources, generalResources] {
            _ = try docker.run(["exec", "--env-file", try XCTUnwrap(resources.envFileURL).path, "-d", resources.container, BotComputerGuestSpec.runAgentPath, resources.runID.value.uuidString.lowercased(), "--", "node", "-e", sentinel])
        }
        for resources in [workspaceResources, generalResources] {
            _ = try docker.run(["exec", resources.container, "sh", "-c", "for i in 1 2 3 4 5 6 7 8 9 10; do if test -f /home/remotecode/.rc-recovery-sentinel.pid && kill -0 $(cat /home/remotecode/.rc-recovery-sentinel.pid); then exit 0; fi; sleep 0.1; done; exit 1"])
        }
        _ = try store.revokeContext(hostID: Self.hostID, botID: bot.id, context: workspaceContext, expectedRevision: workspaceGrant.policyRevision)
        try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        withExtendedLifetime(heartbeats) { Darwin._exit(0) }
    }

    func test_liveRestartReconcilesAWithoutRevivingGrantsOrRuns() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real Docker crash/reopen probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching existing Docker r8 image required; probe never builds an image")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer {
            var cleaned = !FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.json").path)
            if let data = try? Data(contentsOf: root.appendingPathComponent("fixture.json")),
               let fixture = try? JSONDecoder().decode(Fixture.self, from: data) {
                let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
                cleaned = true
                for snapshot in fixture.identities {
                    do {
                        let identity = try BotContextRuntimeIdentity(hostID: snapshot.hostID, botID: snapshot.botID, context: snapshot.context, policyRevision: snapshot.policyRevision)
                        try service.wipe(identity: identity)
                        guard try !docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)),
                              try !docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID)) else {
                            cleaned = false
                            XCTFail("fixture container or network survived cleanup")
                            continue
                        }
                    } catch {
                        cleaned = false
                        XCTFail("fixture cleanup failed: \(error)")
                    }
                }
            }
            if cleaned { try? FileManager.default.removeItem(at: root) }
        }
        let logURL = root.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "AppShellTests.BotContextGuestRecoveryDockerTests/test_childPrepareAndExit", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.rootKey] = root.path
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            XCTFail("child process exceeded 60 seconds; see \(logURL.path)")
            return
        }
        if process.terminationStatus != 0 {
            let diagnostics = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n")
                .filter { $0.contains(": error:") || $0.contains("caught error:") }
                .suffix(5).joined(separator: "\n") ?? "No XCTest error details."
            XCTFail("Child failed with status \(process.terminationStatus): \(diagnostics)")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("ready.json")))
        let db = try SQLiteDB(path: root.appendingPathComponent("bots.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let workspaceContext = BotContext.workspace(fixture.workspace.id)
        let workspaceBinding = try XCTUnwrap(store.getContextBinding(hostID: Self.hostID, botID: fixture.botID, context: workspaceContext))
        let generalBinding = try XCTUnwrap(store.getContextBinding(hostID: Self.hostID, botID: fixture.botID, context: .general))
        XCTAssertFalse(try store.authorizes(hostID: Self.hostID, botID: fixture.botID, context: workspaceContext, action: .read, policyRevision: workspaceBinding.policyRevision))
        XCTAssertTrue(try store.authorizes(hostID: Self.hostID, botID: fixture.botID, context: .general, action: .read, policyRevision: generalBinding.policyRevision))
        let identities = try fixture.identities.map { snapshot in
            try BotContextRuntimeIdentity(hostID: snapshot.hostID, botID: snapshot.botID, context: snapshot.context, policyRevision: snapshot.policyRevision)
        }
        for identity in identities {
            let container = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
            XCTAssertTrue(try docker.containerExists(name: container))
            XCTAssertTrue(try docker.inspect(name: container).running)
            _ = try docker.run(["exec", container, "sh", "-lc", "kill -0 $(cat /home/remotecode/.rc-recovery-sentinel.pid)"])
        }
        let barrier = DistillGuestLaunchBarrier()
        let report = BotGuestLaunchSweep.run(docker: docker, appSupport: support, botIDs: [fixture.botID], barrier: barrier)
        XCTAssertTrue(report.failures.isEmpty, "recovery failures: \(report.failures)")
        XCTAssertEqual(report.reconciled.count, 2)
        let barrierOpened = expectation(description: "launch barrier opens after recovery")
        Task {
            do { try await barrier.wait(); barrierOpened.fulfill() }
            catch { XCTFail("Recovery barrier failed: \(error)"); barrierOpened.fulfill() }
        }
        await fulfillment(of: [barrierOpened], timeout: 60)
        for identity in identities {
            let container = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
            XCTAssertTrue(try docker.containerExists(name: container), "recovery stops, but does not remove, guest container")
            XCTAssertFalse(try docker.inspect(name: container).running, "recovery must stop guest container")
            XCTAssertThrowsError(try docker.run(["exec", container, "sh", "-lc", "kill -0 $(cat /home/remotecode/.rc-recovery-sentinel.pid)"]))
            let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
            let runID = identity.context == workspaceContext ? fixture.workspaceRunID : fixture.generalRunID
            XCTAssertEqual(try Data(contentsOf: guestHome.appendingPathComponent("memory/recovery-marker")), Data("memory-\(runID.value.uuidString)".utf8))
            XCTAssertEqual(try Data(contentsOf: guestHome.appendingPathComponent("browser/recovery-marker")), Data("browser-\(runID.value.uuidString)".utf8))
            let scopedRun = DistillGuestEnvironment.runsDirectory(appSupport: support).appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
            let runName = runID.value.uuidString.lowercased()
            XCTAssertFalse(FileManager.default.fileExists(atPath: scopedRun.appendingPathComponent(runName + ".env").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: guestHome.appendingPathComponent(".distill-context-\(runName)").path))
            let recordData = try Data(contentsOf: scopedRun.appendingPathComponent(runName + ".context.json"))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
            XCTAssertEqual(record["state"] as? String, "ended")
        }
        let secondReport = BotGuestLaunchSweep.run(docker: docker, appSupport: support, botIDs: [fixture.botID], barrier: DistillGuestLaunchBarrier())
        XCTAssertTrue(secondReport.failures.isEmpty, "second recovery must be idempotent: \(secondReport.failures)")
        let secrets = InMemoryBotSecretStore()
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        let workspaceThread = try XCTUnwrap(threadRepo.get(id: fixture.workspaceThreadID))
        let workspaceRequest = AgentRunRequest(runId: fixture.workspaceRunID, threadId: workspaceThread.id, provider: .distill, model: "test", cwd: fixture.workspace.cwd, prompt: "replay", environment: [:])
        XCTAssertThrowsError(try BotContextGuestResources.prepare(request: workspaceRequest, hostID: Self.hostID, store: store, threadRepo: threadRepo, service: service, appSupport: support, workspace: fixture.workspace, registeredWorkspaces: [fixture.workspace.cwd], secretStore: secrets))
        let generalThread = try XCTUnwrap(threadRepo.get(id: fixture.generalThreadID))
        let generalRequest = AgentRunRequest(runId: fixture.generalRunID, threadId: generalThread.id, provider: .distill, model: "test", cwd: BotHome(appSupportDirectory: support, bot: try XCTUnwrap(store.get(id: fixture.botID))).root.path, prompt: "replay", environment: [:])
        XCTAssertThrowsError(try BotContextGuestResources.prepare(request: generalRequest, hostID: Self.hostID, store: store, threadRepo: threadRepo, service: service, appSupport: support, workspace: nil, registeredWorkspaces: [fixture.workspace.cwd], secretStore: secrets))
        XCTAssertEqual(try store.getContextBinding(hostID: Self.hostID, botID: fixture.botID, context: workspaceContext), workspaceBinding)
        XCTAssertEqual(try store.getContextBinding(hostID: Self.hostID, botID: fixture.botID, context: .general), generalBinding)
        for identity in identities {
            XCTAssertFalse(try docker.inspect(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)).running)
        }
        print("Real contextual owner-process crash/reopen probe passed; fixture: \(root.path)")
    }
}
