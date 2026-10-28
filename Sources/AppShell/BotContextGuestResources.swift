import Foundation
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// Prepares scoped resources without admitting a provider process.
final class BotContextGuestResources {
    private static let lock = NSLock()
    // Retain listeners until network cleanup is proven, including failed preparation.
    private static var live: [AgentRunID: BotContextGuestResources] = [:]
    /// Measured ceiling (docs/CONTEXT-RUNTIME-COST.md): 4 simultaneous desktops.
    static let defaultMaximumLiveRuntimes = 4

    let identity: BotContextRuntimeIdentity
    let runID: AgentRunID
    private(set) var container = ""
    private(set) var envFileURL: URL?
    private(set) var configDirectory: URL?
    private let appSupport: URL
    private let service: BotComputerGuestService
    private let gateway: BotGuestMCPGateway?
    private let store: BotStore
    let threadID: AgentThreadID
    private var networkLease: BotContextGatewayLease?
    private var installationAttempted = false
    private var recordStarted = false
    private var homeDirectory: PrivateDirectory?
    private let operationLock = NSLock()
    private var finished = false
    private var stopRequired = false
    private var persistentSession = false
    private var sessionPin: BotConversationContextPin?

    var hasCredentialMaterial: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return !finished && envFileURL != nil && configDirectory != nil
    }
    private var directoryName: String {
        if persistentSession, let sessionPin { return BotContextSessionStore.directoryName(pin: sessionPin) }
        return ".distill-context-\(runID.value.uuidString.lowercased())"
    }

    private init(identity: BotContextRuntimeIdentity, runID: AgentRunID, threadID: AgentThreadID, store: BotStore, service: BotComputerGuestService, gateway: BotGuestMCPGateway?, appSupport: URL) {
        self.appSupport = appSupport
        self.identity = identity
        self.runID = runID
        self.service = service
        self.gateway = gateway
        self.store = store
        self.threadID = threadID
    }

    static func prepare(
        request: AgentRunRequest,
        hostID: String,
        store: BotStore,
        threadRepo: AgentThreadRepository,
        service: BotComputerGuestService,
        appSupport: URL,
        workspace: Workspace?,
        registeredWorkspaces: Set<String>,
        secretStore: (any BotSecretStore)?,
        parentRunID: AgentRunID? = nil,
        providerConfiguration: String = "",
        persistentSession: Bool = false,
        maximumLiveRuntimes: Int = BotContextGuestResources.defaultMaximumLiveRuntimes
    ) throws -> BotContextGuestResources {
        do {
            guard request.runAsUser == nil || request.runAsUser?.uid == getuid() else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            guard let pin = try store.conversationContextPin(linkedTo: request.threadId), pin.hostID == hostID,
                  let thread = try threadRepo.get(id: request.threadId),
                  thread.actor == .bot(pin.botID), thread.executionTarget == .vm,
                  thread.runAsUser == nil || thread.runAsUser?.uid == getuid(),
                  try threadRepo.guestPlacement(of: request.threadId)?.guestRuntime == BotGuestRuntime.distillV1,
                  let conversation = try store.conversation(id: pin.conversationID),
                  conversation.botID == pin.botID, conversation.linkedAgentThreadID == thread.id,
                  let binding = try store.getContextBinding(hostID: hostID, botID: pin.botID, context: pin.context),
                  binding.policyRevision == pin.policyRevision else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            let identity = try store.contextRuntimeIdentity(pin: pin, threadID: thread.id)
            let authorize: @Sendable () -> Bool = {
                let actions: [BotContextAction] = workspace == nil ? [.read, .send, .configure] : [.read, .send, .configure, .files]
                return actions.allSatisfy {
                    (try? store.authorizes(hostID: hostID, botID: pin.botID, context: pin.context, action: $0, policyRevision: pin.policyRevision)) == true
                } && (try? store.conversationContextPin(linkedTo: request.threadId)) == pin
                    && (try? store.authorizesContextDelegation(hostID: hostID, runID: request.runId, threadID: request.threadId)) == true
            }
            guard authorize() else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            let home = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: identity.storageBotID)
            switch pin.context {
            case .general:
                guard workspace == nil, thread.workspaceId == nil else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
            case .workspace(let id):
                guard let workspace, workspace.id == id, thread.workspaceId == id,
                      request.cwd == workspace.cwd, registeredWorkspaces.contains(workspace.cwd) else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
            }
            if persistentSession {
                try BotContextSessionStore.validate(pin: pin, threadID: request.threadId,
                    parentRunID: parentRunID, cwd: request.cwd, resumeCursor: request.providerThreadId,
                    appSupport: appSupport, authorizes: authorize, virtualMachineID: identity.virtualMachineID)
            }
            let context = BotGuestMCPGateway.ContextBinding(pin: pin, threadID: request.threadId)
            let gateway = secretStore.map { BotGuestMCPGateway(context: context, contextStore: store, secretStore: $0) }
            let resources = BotContextGuestResources(identity: identity, runID: request.runId, threadID: request.threadId, store: store, service: service, gateway: gateway, appSupport: appSupport)
            resources.persistentSession = persistentSession
            resources.sessionPin = persistentSession ? pin : nil
            resources.operationLock.lock()
            var claimed = false
            do {
                defer { resources.operationLock.unlock() }
                var atCapacity = false
                var liveRunIDs: Set<AgentRunID> = []
                let didClaim = lock.withLock {
                    let scope = appSupport.resolvingSymlinksInPath().standardizedFileURL
                    // Capacity counts runtimes (VMs); runs of one identity share its VM.
                    let runtimes = Set(live.values.filter { $0.appSupport.resolvingSymlinksInPath().standardizedFileURL == scope }
                        .map(\.identity.storageBotID))
                    if !runtimes.contains(identity.storageBotID), runtimes.count >= maximumLiveRuntimes {
                        atCapacity = true
                        return false
                    }
                    guard live[request.runId] == nil else { return false }
                    liveRunIDs = Set(live.values.filter { $0.identity.storageBotID == identity.storageBotID }.map(\.runID))
                    live[request.runId] = resources
                    return true
                }
                guard didClaim else {
                    throw atCapacity
                        ? BotComputerGuestServiceError.contextualRuntimeCapacityReached(limit: maximumLiveRuntimes)
                        : BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
                claimed = true
                if let parentRunID {
                    _ = try store.recordContextDelegation(hostID: hostID, parentRunID: parentRunID, childRunID: request.runId, childThreadID: request.threadId)
                }
                guard authorize() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                try BotContextGuestRecovery.begin(identity: identity, runID: request.runId, conversationID: persistentSession ? pin.conversationID : nil, appSupport: appSupport, liveRunIDs: liveRunIDs)
                resources.recordStarted = true
                if let secretStore, let gateway {
                    let adapter = BotContextSecretStore(identity: identity, store: secretStore, authorizes: authorize)
                    let trustedEnvironment = try BotSecretEnvironment.applying(to: [
                        BotSecretEnvironment.botIDEnvironmentKey: pin.botID.value.uuidString,
                        BotPeerDelegation.threadEnvironmentKey: thread.id.value.uuidString,
                    ], store: adapter)
                    resources.container = try service.provision(contextBinding: binding, workspace: workspace, registeredWorkspaces: registeredWorkspaces, requestingThreadID: request.threadId, virtualMachineID: identity.virtualMachineID).containerID
                    guard authorize() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                    let run = request.runId.value.uuidString.lowercased()
                    let issued = try gateway.issue(.init(runID: run, hostEnvironment: [:], context: context))
                    resources.installationAttempted = true
                    resources.networkLease = try service.installGatewayLease(identity: identity, runID: request.runId, port: issued.port)
                    let parent = try PrivateDirectory(home, create: false)
                    resources.homeDirectory = parent
                    let directory: URL
                    if persistentSession {
                        directory = try BotContextSessionStore.prepare(
                            pin: pin, threadID: request.threadId, parentRunID: parentRunID,
                            cwd: request.cwd, resumeCursor: request.providerThreadId,
                            appSupport: appSupport, authorizes: authorize, virtualMachineID: identity.virtualMachineID
                        )
                    } else {
                        directory = home.appendingPathComponent(resources.directoryName, isDirectory: true)
                        guard mkdir(directory.path, 0o700) == 0 else {
                            throw DistillGuestCredentialError.writeFailed(path: directory.path, errno: errno)
                        }
                    }
                    resources.configDirectory = directory
                    let rendered = DistillGuestConfig.render(hostConfig: providerConfiguration, gatewayPort: issued.port, servers: [
                        .init(name: BotSelfConfigCatalog.serverName, toolTimeoutSeconds: 900),
                    ], hostEnvironment: [:])
                    guard rendered.droppedModels[request.model] == nil else {
                        throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                    }
                    resources.envFileURL = try DistillGuestEnvironment.writeRunFiles(
                        rendered: rendered, configDirectory: directory,
                        guestDistillHome: BotComputerGuestSpec.guestUserHome + "/" + resources.directoryName,
                        providerEnvironment: trustedEnvironment, runID: run, gatewayToken: issued.token,
                        gitIdentity: nil, codexClientVersion: nil,
                        runsDirectory: DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
                            .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
                    )
                    guard authorize() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                } else {
                    resources.container = try service.provision(contextBinding: binding, workspace: workspace, registeredWorkspaces: registeredWorkspaces, requestingThreadID: request.threadId, virtualMachineID: identity.virtualMachineID).containerID
                    guard authorize() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                }
                return resources
            } catch {
                if claimed {
                    do { try resources.cancel() }
                    catch { NSLog("Bot context preparation cleanup unconfirmed run=%@ error=%@", request.runId.value.uuidString.lowercased(), String(describing: error)) }
                }
                throw error
            }
        }
    }

    func finish() throws {
        try operationLock.withLock { try finishLocked(stopRuntime: false) }
    }

    func cancel() throws {
        try operationLock.withLock { try finishLocked(stopRuntime: true) }
    }

    static func requestFinish(runID: AgentRunID, threadID: AgentThreadID, store: BotStore, appSupport: URL) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let edges = try store.closeContextDelegationTree(runID: runID)
                let matches = lock.withLock {
                    live.values.filter { resource in
                        resource.appSupport.resolvingSymlinksInPath().standardizedFileURL == appSupport.resolvingSymlinksInPath().standardizedFileURL
                            && ((resource.runID == runID && resource.threadID == threadID)
                                || edges.contains { edge in
                                    edge.childRunID == resource.runID && edge.childThreadID == resource.threadID
                                        && edge.childPin.botID == resource.identity.botID && edge.childPin.context == resource.identity.context
                                })
                    }
                }
                for resource in matches {
                    do {
                        if resource.runID == runID && resource.threadID == threadID { try resource.finish() }
                        else { try resource.cancel() }
                    } catch {
                        NSLog("Bot context finish failed run=%@ error=%@", resource.runID.value.uuidString.lowercased(), String(describing: error))
                    }
                }
            } catch {
                NSLog("Bot context finish failed run=%@ error=%@", runID.value.uuidString.lowercased(), String(describing: error))
            }
        }
    }

    static func requestRevocation(binding: BotContextBinding, store: BotStore, appSupport: URL) throws {
        func invalid(_ pin: BotConversationContextPin) -> Bool {
            pin.hostID == binding.hostID && pin.botID == binding.botID && pin.context == binding.context
                && (binding.state != .active || pin.policyRevision != binding.policyRevision)
        }
        let edges = try store.contextDelegations()
        let affectedEdges = edges.filter { invalid($0.parentPin) || invalid($0.childPin) }
        let resources = lock.withLock {
            live.values.filter { $0.appSupport.resolvingSymlinksInPath().standardizedFileURL == appSupport.resolvingSymlinksInPath().standardizedFileURL
                && $0.identity.hostID == binding.hostID && $0.identity.botID == binding.botID && $0.identity.context == binding.context
                && (binding.state != .active || $0.identity.policyRevision != binding.policyRevision) }
        }
        guard !affectedEdges.isEmpty || !resources.isEmpty else { return }
        var roots = Set(resources.map(\.runID))
        for edge in affectedEdges {
            if invalid(edge.parentPin) { roots.insert(edge.parentRunID) }
            if invalid(edge.childPin) { roots.insert(edge.childRunID) }
        }
        var allRunIDs = roots
        var allEdges: [BotContextDelegation] = []
        for runID in roots {
            let descendants = try store.closeContextDelegationTree(runID: runID)
            allEdges.append(contentsOf: descendants)
            allRunIDs.formUnion(descendants.map(\.childRunID))
        }
        DispatchQueue.global(qos: .utility).async {
            let captured = lock.withLock {
                live.values.filter { resource in
                    resource.appSupport.resolvingSymlinksInPath().standardizedFileURL == appSupport.resolvingSymlinksInPath().standardizedFileURL
                        && ((allRunIDs.contains(resource.runID) && roots.contains(resource.runID))
                            || allEdges.contains { edge in
                                edge.childRunID == resource.runID && edge.childThreadID == resource.threadID
                                    && edge.childPin.botID == resource.identity.botID && edge.childPin.context == resource.identity.context
                            })
                }
            }
            for resource in captured {
                do { try resource.cancel() }
                catch { NSLog("Bot context revocation failed run=%@ error=%@", resource.runID.value.uuidString.lowercased(), String(describing: error)) }
            }
        }
    }

    /// Call with `Self.lock` held.
    private var sharesRuntimeLocked: Bool {
        Self.live.values.contains { $0 !== self && $0.identity.storageBotID == identity.storageBotID }
    }

    private func finishLocked(stopRuntime: Bool) throws {
        stopRequired = stopRequired || stopRuntime
        if finished {
            // A shared VM may already belong to another bot after this cleanup.
            guard identity.virtualMachineID == nil else { return }
            guard stopRequired else { return }
            let ownsScope = Self.lock.withLock {
                guard !sharesRuntimeLocked, Self.live[runID] == nil || Self.live[runID] === self else { return false }
                Self.live[runID] = self
                return true
            }
            guard ownsScope else { return }
            try service.stopForContextRecovery(identity: identity)
            Self.lock.withLock {
                if Self.live[runID] === self { Self.live[runID] = nil }
            }
            return
        }
        gateway?.revoke(runID: runID.value.uuidString.lowercased())
        // Remove distributed credentials even if the network cannot be reconciled.
        if let envFileURL {
            guard unlink(envFileURL.path) == 0 || errno == ENOENT else {
                throw DistillGuestEnvironmentError.writeFailed(path: envFileURL.path, errno: errno)
            }
            self.envFileURL = nil
        }
        let edges = try store.closeContextDelegationTree(runID: runID)
        let descendants = Self.lock.withLock {
            edges.compactMap { edge -> BotContextGuestResources? in
                guard edge.childRunID != runID,
                      let child = Self.live.values.first(where: {
                          $0.runID == edge.childRunID && $0.threadID == edge.childThreadID
                              && edge.childPin.botID == $0.identity.botID && edge.childPin.context == $0.identity.context
                              && $0.appSupport.resolvingSymlinksInPath().standardizedFileURL == appSupport.resolvingSymlinksInPath().standardizedFileURL
                      }) else { return nil }
                return child
            }
        }
        var descendantError: Error?
        for child in descendants {
            do { try child.cancel() }
            catch { if descendantError == nil { descendantError = error } }
        }
        if let descendantError { throw descendantError }
        // Another live run of this identity still uses the VM; its own end stops it.
        if stopRequired, !Self.lock.withLock({ sharesRuntimeLocked }) { try service.stopForContextRecovery(identity: identity) }
        if let networkLease {
            try service.revokeGatewayLease(networkLease)
        } else if installationAttempted {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        gateway?.stop()
        if let homeDirectory {
            if persistentSession {
                if let configDirectory {
                    let directory = try PrivateDirectory(configDirectory, create: false)
                    defer { directory.close() }
                    if (try directory.entriesChecked()).contains("config.toml") {
                        guard directory.remove("config.toml") else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                        try directory.synchronize()
                        guard !(try directory.entriesChecked()).contains("config.toml") else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                    }
                }
            } else if configDirectory != nil {
                homeDirectory.removeTree(directoryName)
                guard try !homeDirectory.entriesChecked().contains(directoryName) else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
            }
            try homeDirectory.synchronize()
            homeDirectory.close()
            self.homeDirectory = nil
        }
        if recordStarted {
            try BotContextGuestRecovery.end(identity: identity, runID: runID, appSupport: appSupport)
        }
        finished = true
        Self.lock.withLock { if Self.live[runID] === self { Self.live[runID] = nil } }
    }
}
