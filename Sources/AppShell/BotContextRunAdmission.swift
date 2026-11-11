import Foundation
import AgentRuntime
import CoreModel
import Persistence

final class BotContextRunAdmissions: @unchecked Sendable {
    struct Admission: Sendable {
        let runID: AgentRunID
        let threadID: AgentThreadID
        let pin: BotConversationContextPin
        let parentRunID: AgentRunID?
        let model: String
        let cwd: String
        let resumeCursor: String?
        let permit: AgentRunAcceptancePermit
        let providerConfiguration: String
        let validates: @Sendable () -> Bool
        let recordOpened: @Sendable (String) throws -> Void

        init(runID: AgentRunID, threadID: AgentThreadID, pin: BotConversationContextPin,
             parentRunID: AgentRunID?, model: String, cwd: String, resumeCursor: String? = nil,
             permit: AgentRunAcceptancePermit, providerConfiguration: String,
             validates: @escaping @Sendable () -> Bool,
             recordOpened: @escaping @Sendable (String) throws -> Void = { _ in }) {
            self.runID = runID
            self.threadID = threadID
            self.pin = pin
            self.parentRunID = parentRunID
            self.model = model
            self.cwd = cwd
            self.resumeCursor = resumeCursor
            self.permit = permit
            self.providerConfiguration = providerConfiguration
            self.validates = validates
            self.recordOpened = recordOpened
        }
    }

    private let lock = NSLock()
    private var admissions: [AgentRunID: Admission] = [:]

    func register(_ admission: Admission) throws {
        lock.lock()
        defer { lock.unlock() }
        guard admissions[admission.runID] == nil else {
            throw BotStoreError.notFound
        }
        admissions[admission.runID] = admission
    }

    func consume(_ request: AgentRunRequest) throws -> Admission? {
        let admission = try lock.withLock { () throws -> Admission? in
            guard let admission = admissions[request.runId] else { return nil }
            guard request.threadId == admission.threadID, request.provider == .distill,
                  request.model == admission.model, request.cwd == admission.cwd,
                  let permit = request.acceptancePermit, permit === admission.permit,
                  request.providerBinary == nil, request.extraArgs.isEmpty,
                  request.providerThreadId == admission.resumeCursor else { throw BotStoreError.notFound }
            admissions.removeValue(forKey: admission.runID)
            return admission
        }
        guard let admission else { return nil }
        guard admission.validates() else { throw BotStoreError.notFound }
        return admission
    }

    func hasAdmission(for runID: AgentRunID) -> Bool {
        lock.withLock { admissions[runID] != nil }
    }

    func hasAdmission(threadID: AgentThreadID) -> Bool {
        lock.withLock { admissions.values.contains { $0.threadID == threadID } }
    }

    func discard(runID: AgentRunID) {
        lock.lock()
        defer { lock.unlock() }
        admissions.removeValue(forKey: runID)
    }
}

extension BotContextRunAdmissions {
    static func configuration(model: String) throws -> String {
        let prefix = "openrouter/"
        guard model.hasPrefix(prefix) else { throw BotStoreError.notFound }
        let slug = String(model.dropFirst(prefix.count))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        guard slug.contains("/"), !slug.hasPrefix("/"), !slug.hasSuffix("/"),
              slug.unicodeScalars.allSatisfy(allowed.contains) else { throw BotStoreError.notFound }
        func quoted(_ value: String) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        return """
        [model.\(try quoted(model))]
        model = \(try quoted(slug))
        base_url = "https://openrouter.ai/api/v1"
        env_key = "OPENROUTER_API_KEY"
        """
    }

    static func authorizes(
        pin: BotConversationContextPin, threadID: AgentThreadID, runID: AgentRunID,
        parentRunID: AgentRunID?, hostID: String, store: BotStore,
        threadRepo: AgentThreadRepository, runRepo: AgentRunRepository
    ) -> Bool {
        do {
            guard pin.hostID == hostID,
                  try store.conversationContextPin(linkedTo: threadID) == pin,
                  let thread = try threadRepo.get(id: threadID), thread.actor == .bot(pin.botID),
                  thread.provider == .distill, thread.executionTarget == .vm,
                  thread.runAsUser == nil || thread.runAsUser?.uid == getuid(),
                  try threadRepo.guestPlacement(of: threadID)?.guestRuntime == BotGuestRuntime.distillV1,
                  let conversation = try store.conversation(id: pin.conversationID),
                  conversation.botID == pin.botID, conversation.linkedAgentThreadID == threadID else { return false }
            let actions: [BotContextAction] = pin.context == .general
                ? [.read, .send, .configure] : [.read, .send, .configure, .files]
            guard try actions.allSatisfy({ try store.authorizes(hostID: hostID, botID: pin.botID,
                context: pin.context, action: $0, policyRevision: pin.policyRevision) }),
                try store.authorizesContextDelegation(hostID: hostID, runID: runID, threadID: threadID) else { return false }
            if let parentRunID {
                guard let parent = try runRepo.get(id: parentRunID), parent.status == .running,
                      let parentPin = try store.conversationContextPin(linkedTo: parent.threadId),
                      parentPin.hostID == hostID, parentPin.context == pin.context, parentPin.botID != pin.botID,
                      try store.authorizes(hostID: hostID, botID: parentPin.botID, context: parentPin.context,
                          action: .delegate, policyRevision: parentPin.policyRevision),
                      try store.authorizesContextDelegation(hostID: hostID, runID: parentRunID, threadID: parent.threadId) else { return false }
            }
            return true
        } catch { return false }
    }
}

extension AppContext {
    func startContextualRun(_ request: AgentRunRequest, parentRunID: AgentRunID? = nil) async throws -> AgentRunID {
        guard hostsBotGroupConversations, request.provider == .distill,
              request.providerInstanceId == nil || request.providerInstanceId == AgentProvider.distill.rawValue,
              request.providerBinary == nil, request.environment.isEmpty, request.extraArgs.isEmpty,
              request.providerThreadId == nil,
              request.runAsUser == nil || request.runAsUser?.uid == getuid(),
              let pin = try botStore.conversationContextPin(linkedTo: request.threadId),
              let thread = try threadRepo.get(id: request.threadId), thread.model == request.model,
              thread.permissionMode == request.permissionMode else { throw BotStoreError.notFound }
        switch pin.context {
        case .general:
            guard thread.workspaceId == nil, request.cwd == BotComputerGuestSpec.guestUserHome else { throw BotStoreError.notFound }
        case .workspace(let workspaceID):
            guard thread.workspaceId == workspaceID, let workspace = state.workspaces[workspaceID],
                  workspace.cwd == request.cwd else { throw BotStoreError.notFound }
        }
        let configuration = try BotContextRunAdmissions.configuration(model: request.model)
        let store = botStore
        let threads = threadRepo
        let runs = runRepo
        let hostID = liveActivityHostIdentity.serverId
        let secretStore = contextualSecretStore
        let identity = try store.contextRuntimeIdentity(pin: pin, threadID: request.threadId)
        let authorizes: @Sendable () -> Bool = {
            BotContextRunAdmissions.authorizes(pin: pin, threadID: request.threadId, runID: request.runId,
                parentRunID: parentRunID, hostID: hostID, store: store, threadRepo: threads, runRepo: runs)
        }
        let scopedSecrets = BotContextSecretStore(identity: identity, store: secretStore, authorizes: authorizes)
        let support = appSupportDirectory
        guard authorizes(), let key = try scopedSecrets.load(botID: pin.botID, name: "OPENROUTER_API_KEY"),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains("\n"), !key.contains("\r") else { throw BotStoreError.notFound }
        let resumeCursor: String?
        do { resumeCursor = try coordinator.resumeCursorForRun(request) }
        catch { throw DistillGuestLaunchError.unavailable(L("The contextual provider session cannot be resumed safely.")) }
        let storedCursor = try threadRepo.providerThreadId(of: request.threadId)
        if let storedCursor, !storedCursor.isEmpty {
            guard resumeCursor == storedCursor else {
                throw DistillGuestLaunchError.unavailable(L("The contextual provider session cannot be resumed safely."))
            }
        } else if resumeCursor != nil {
            throw DistillGuestLaunchError.unavailable(L("The contextual provider session cannot be resumed safely."))
        }
        let validates: @Sendable () -> Bool = {
            guard authorizes(), let key = try? scopedSecrets.load(botID: pin.botID, name: "OPENROUTER_API_KEY"),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.contains("\n"), !key.contains("\r") else { return false }
            return (try? BotContextSessionStore.validate(pin: pin, threadID: request.threadId,
                parentRunID: parentRunID, cwd: request.cwd, resumeCursor: resumeCursor,
                appSupport: support, authorizes: authorizes, virtualMachineID: identity.virtualMachineID)) != nil
        }
        let recordOpened: @Sendable (String) throws -> Void = { sessionID in
            guard validates() else { throw BotStoreError.notFound }
            try BotContextSessionStore.recordOpened(sessionID: sessionID, pin: pin,
                threadID: request.threadId, parentRunID: parentRunID, cwd: request.cwd,
                expectedResumeCursor: resumeCursor, appSupport: support, authorizes: authorizes, virtualMachineID: identity.virtualMachineID)
        }
        guard validates() else { throw BotStoreError.notFound }
        let permit = AgentRunAcceptancePermit()
        var admitted = AgentRunRequest(
            runId: request.runId, threadId: request.threadId, provider: request.provider,
            providerInstanceId: request.providerInstanceId, model: request.model, cwd: request.cwd,
            prompt: request.prompt, userMessageContent: request.userMessageContent,
            attachments: request.attachments, providerThreadId: resumeCursor,
            permissionMode: request.permissionMode, reasoningEffort: request.reasoningEffort,
            reasoningModel: request.reasoningModel,
            distillMainEffortSelection: request.distillMainEffortSelection,
            distillReasoningEffortSelection: request.distillReasoningEffortSelection,
            distillExecutionMode: request.distillExecutionMode, serviceTier: request.serviceTier,
            interactionMode: request.interactionMode, providerBinary: request.providerBinary,
            environment: request.environment, extraArgs: request.extraArgs,
            runAsUser: request.runAsUser, acceptancePermit: permit,
            contextSnapshot: request.contextSnapshot, preparedContextSeed: request.preparedContextSeed
        )
        admitted.priorProviderSessionModel = request.priorProviderSessionModel
        admitted.priorProviderSessionRetired = request.priorProviderSessionRetired
        admitted.priorConversationTail = request.priorConversationTail
        try contextualRunAdmissions.register(.init(runID: request.runId, threadID: request.threadId,
            pin: pin, parentRunID: parentRunID, model: request.model, cwd: request.cwd,
            resumeCursor: resumeCursor, permit: permit,
            providerConfiguration: configuration, validates: validates, recordOpened: recordOpened))
        defer { contextualRunAdmissions.discard(runID: request.runId) }
        return try await coordinator.startRun(admitted)
    }

    func startContextualPeerRun(parentRunID: AgentRunID, peerBotID: BotID, prompt: String) async throws -> AgentRunID {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parent = try runRepo.get(id: parentRunID), parent.status == .running,
              let parentThread = try threadRepo.get(id: parent.threadId),
              let parentPin = try botStore.conversationContextPin(linkedTo: parent.threadId),
              parentPin.hostID == liveActivityHostIdentity.serverId, parentPin.botID != peerBotID,
              BotContextRunAdmissions.authorizes(pin: parentPin, threadID: parent.threadId, runID: parentRunID,
                  parentRunID: nil, hostID: liveActivityHostIdentity.serverId, store: botStore,
                  threadRepo: threadRepo, runRepo: runRepo),
              try botStore.authorizes(hostID: parentPin.hostID, botID: parentPin.botID, context: parentPin.context,
                  action: .delegate, policyRevision: parentPin.policyRevision),
              try botStore.authorizesContextDelegation(hostID: parentPin.hostID, runID: parentRunID, threadID: parent.threadId),
              let peer = try botStore.get(id: peerBotID),
              let binding = try botStore.getContextBinding(hostID: parentPin.hostID, botID: peerBotID, context: parentPin.context) else {
            throw BotStoreError.notFound
        }
        _ = try BotContextRunAdmissions.configuration(model: parentThread.model)
        let actions: [BotContextAction] = parentPin.context == .general ? [.read, .send, .configure] : [.read, .send, .configure, .files]
        guard try actions.allSatisfy({ try botStore.authorizes(hostID: parentPin.hostID, botID: peerBotID,
            context: parentPin.context, action: $0, policyRevision: binding.policyRevision) }) else { throw BotStoreError.notFound }
        let cwd: String
        switch parentPin.context {
        case .general: cwd = BotComputerGuestSpec.guestUserHome
        case .workspace(let workspaceID):
            guard let workspace = state.workspaces[workspaceID] else { throw BotStoreError.notFound }
            cwd = workspace.cwd
        }
        if let machineID = try botStore.executionDestination(botID: peerBotID).virtualMachineID,
           try botStore.contextRuntimeIdentity(pin: parentPin, threadID: parent.threadId).virtualMachineID == machineID {
            throw DistillGuestLaunchError.unavailable(L("A bot cannot delegate to another bot while both use the same VM. Choose a different VM for the other bot."))
        }
        let peerIdentity = try BotContextRuntimeIdentity(binding: binding)
        let scopedStore = BotContextSecretStore(identity: peerIdentity, store: contextualSecretStore, authorizes: { [botStore] in
            (try? actions.allSatisfy { try botStore.authorizes(hostID: parentPin.hostID, botID: peerBotID,
                context: parentPin.context, action: $0, policyRevision: binding.policyRevision) }) == true
        })
        guard let key = try scopedStore.load(botID: peerBotID, name: "OPENROUTER_API_KEY"),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !key.contains("\n"), !key.contains("\r") else {
            throw BotStoreError.notFound
        }
        let thread = AgentThread(workspaceId: parentThread.workspaceId, title: L("Delegation to %1$@", peer.name),
            provider: .distill, model: parentThread.model, permissionMode: parentThread.permissionMode,
            reasoningEffort: parentThread.reasoningEffort, serviceTier: parentThread.serviceTier)
        _ = try botStore.createContextualConversation(BotConversation(botID: peerBotID, title: thread.title,
            linkedAgentThreadID: thread.id), newThread: thread, hostID: parentPin.hostID,
            context: parentPin.context, policyRevision: binding.policyRevision)
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: thread.model, cwd: cwd,
            prompt: prompt, permissionMode: thread.permissionMode, reasoningEffort: thread.reasoningEffort,
            serviceTier: thread.serviceTier)
        coordinator.registerDelegatedRun(request.runId, threadId: thread.id, parentRunId: parentRunID)
        return try await startContextualRun(request, parentRunID: parentRunID)
    }
}
