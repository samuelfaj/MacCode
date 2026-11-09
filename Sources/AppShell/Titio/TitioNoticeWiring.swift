import AgentRuntime
import AppKit
import CoreModel
import Foundation
import Persistence
import SocketServer
import Surfaces

/// Weak link from the notice hub's hooks to the app context (set once the
/// router is attached, so the hub never keeps the context alive).
final class TitioNoticeContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: AppContext?

    var context: AppContext? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The §16 language inputs: the user's recent messages in any Titio
/// conversation (newest first) and recent card labels (a card tap is stored
/// as a user row with its label), read off the MainActor for each voice call.
final class TitioLanguageInputSource: @unchecked Sendable {
    /// How many recent user messages the walk-back may look at.
    static let recentLimit = 12
    private let botStore: BotStore
    private let messageRepo: AgentMessageRepository
    private let notices: TitioNoticeRepository?

    init(botStore: BotStore, messageRepo: AgentMessageRepository, notices: TitioNoticeRepository? = nil) {
        self.botStore = botStore
        self.messageRepo = messageRepo
        self.notices = notices
    }

    func recentUserTexts() -> (texts: [String], labels: Set<String>) {
        let texts = readRecentUserTexts()
        let labels = (try? notices?.recentCardLabels()) ?? []
        return (texts, labels)
    }

    private func readRecentUserTexts() -> [String] {
        guard let titio = (try? botStore.list(includeHidden: true))?
            .first(where: { $0.handle.lowercased() == TitioBot.handle && $0.deletedAt == nil }),
              let conversations = try? botStore.listConversations(botID: titio.id) else { return [] }
        var users: [AgentMessage] = []
        for thread in Set(conversations.compactMap(\.linkedAgentThreadID)) {
            guard let recent = try? messageRepo.listRecent(threadId: thread, limit: 30) else { continue }
            users += recent.filter { $0.role == .user }
        }
        return users.sorted { $0.createdAt > $1.createdAt }.prefix(Self.recentLimit).map(\.content)
    }
}

extension AppContext {
    /// Production hooks for `TitioNoticeCenter`. Ledger, message and store
    /// work stays on the hub's actor; only the desk/state reads hop to the
    /// MainActor.
    nonisolated static func makeTitioNoticeHooks(
        box: TitioNoticeContextBox,
        db: SQLiteDB,
        botStore: BotStore,
        messageRepo: AgentMessageRepository,
        runRepo: AgentRunRepository,
        bridge: PrivateNotificationBridge,
        hostID: String
    ) -> TitioNoticeHooks {
        let language = TitioLanguageInputSource(botStore: botStore, messageRepo: messageRepo, notices: TitioNoticeRepository(db: db))
        let bindings = BotAttentionPushBindingStore(db: db)
        let settings = SettingsStore(db: db)
        return TitioNoticeHooks(
            resolveInbox: { lang in
                await MainActor.run { box.context?.router?.resolveTitioInbox(language: lang) }
            },
            isInboxViewed: { target in
                await MainActor.run { box.context?.router?.isTitioInboxViewed(target.conversationID) ?? false }
            },
            isTitioRunActive: { target in
                ((try? runRepo.latestActive(for: target.threadID)) ?? nil) != nil
            },
            languageInputs: {
                let recent = language.recentUserTexts()
                return TitioNoticeLanguageInputs(
                    recentUserTexts: recent.texts,
                    cardLabels: recent.labels,
                    preferredLanguages: Locale.preferredLanguages
                )
            },
            messagePosted: { posted in
                EventBus.shared.publish(
                    kind: .agentMessageAppended,
                    payload: AgentMessageTransport.appendedEventPayload(from: posted.message, bodyRevision: posted.bodyRevision)
                )
                await MainActor.run {
                    guard let router = box.context?.router else { return }
                    router.botsViewModel?.appendHostAssistantMessage(
                        botID: posted.target.botID,
                        conversationID: posted.target.conversationID,
                        message: posted.message,
                        conversation: posted.conversation
                    )
                    router.projectTitioInboxMessage(posted.message)
                }
            },
            inboxChanged: { snapshot in
                await MainActor.run { box.context?.liveActivitySyncCoordinator.submitTitio(snapshot) }
                EventBus.shared.publish(kind: .botUpdated, payload: AppContext.titioInboxEventPayload(snapshot))
            },
            messagesRemoved: { target, ids in
                EventBus.shared.publish(
                    kind: .agentMessagesRemoved,
                    payload: AppContext.messagesRemovedEventPayload(threadID: target.threadID, messageIDs: ids)
                )
                await MainActor.run {
                    guard let router = box.context?.router else { return }
                    router.botsViewModel?.removeHostMessages(
                        botID: target.botID, conversationID: target.conversationID, messageIDs: ids
                    )
                    router.projectTitioInboxRemoval(ids, threadID: target.threadID)
                }
            },
            postBanner: { content in
                SystemNotifier.shared.post(content, settings: settings.load())
            },
            deliverPush: { content in
                guard bridge.hasAlertPushTarget else { return true }
                return await bridge.deliver(content.withSound(settings.load().notificationSoundEnabled))
            },
            pushBinding: {
                TitioNoticePushBinding(profileID: bindings.unique(hostID: hostID)?.profileID, hostID: hostID)
            },
            workspaceName: { workspaceID in
                await MainActor.run { box.context?.state.workspaces[workspaceID]?.name }
            },
            isFocusedSuccess: { event in
                await MainActor.run { box.context?.router?.isFocusedPetSuccess(event) ?? false }
            },
            observeAgentEvent: { event in
                guard let context = box.context else { return false }
                return await context.observeTitioAgentEvent(event)
            }
        )
    }

    /// `agent.messages.removed {thread_id, message_ids}` (contract §3).
    nonisolated static func messagesRemovedEventPayload(threadID: AgentThreadID, messageIDs: [AgentMessageID]) -> JSONValue {
        .object([
            "thread_id": .string(threadID.value.uuidString.lowercased()),
            "message_ids": .array(messageIDs.map { .string($0.value.uuidString.lowercased()) }),
        ])
    }

    /// Titio's writer: one headless call on the inbox thread's own provider,
    /// model and run-as-user. The thread is read here, off the MainActor;
    /// the binary and environment come from the same resolution a provider
    /// update uses (one short MainActor hop, no process work there).
    nonisolated static func makeTitioVoiceWriter(box: TitioNoticeContextBox, db: SQLiteDB) -> TitioVoiceWriting {
        // Its own repository: the shared one's test counters are not thread-safe.
        let threadRepo = AgentThreadRepository(db: db)
        return TitioVoiceCLIWriter { threadID in
            guard let threadID, let thread = (try? threadRepo.get(id: threadID)) ?? nil else { return nil }
            let resolved = await MainActor.run {
                box.context?.router?.providerUpdateTarget(provider: thread.provider, instanceId: thread.providerInstanceId)
            }
            guard let resolved else { return nil }
            return TitioVoiceRoute(
                provider: thread.provider,
                binaryPath: resolved.binaryPath,
                model: thread.model,
                environment: resolved.environment,
                runAsUser: thread.runAsUser
            )
        }
    }

    /// The `bot.updated` payload of an inbox change. No `method`: it is not a
    /// mutation, and a paired roster applies a method-less `titio_inbox`
    /// payload as is, without a full `bot.list` refetch per notice (§10).
    nonisolated static func titioInboxEventPayload(_ snapshot: TitioInboxSnapshot) -> JSONValue {
        .object([
            "reason": .string("titio_inbox"),
            "bot_id": .string(snapshot.botID.value.uuidString.lowercased()),
            "titio_inbox": snapshot.wireObject,
        ])
    }

    /// Production host side effects of card actions (§7 step 4). The pending
    /// request check reads SQLite on the hub's actor; router and Bots calls
    /// hop to the MainActor where those APIs live.
    nonisolated static func makeTitioNoticeActionHooks(
        box: TitioNoticeContextBox,
        db: SQLiteDB,
        botStore: BotStore
    ) -> TitioNoticeActionHooks {
        let pending = ProviderPendingCallbackRepository(db: db)
        let runs = AgentRunRepository(db: db)
        @Sendable func router() async throws -> AppCommandRouter {
            guard let router = await MainActor.run(body: { box.context?.router }) else {
                throw TitioNoticeActionError(reason: "MacCode is not ready")
            }
            return router
        }
        return TitioNoticeActionHooks(
            isRequestOpen: { thread, request, kind, expectedRunID in
                if let expectedRunID {
                    guard let active = try? runs.latestActive(for: thread),
                          active.id.value.uuidString.caseInsensitiveCompare(expectedRunID) == .orderedSame else { return false }
                }
                // Older notices without a run binding retain the provider's check.
                guard let row = (try? pending.get(
                    threadId: thread, requestId: request, kind: kind == .approval ? .approval : .userInput
                )) ?? nil else { return true }
                return row.state == .pending
            },
            respondRequest: { thread, request, decision in
                let response: AgentProviderRequestResponse
                switch decision {
                case .approve: response = .approve
                case .approveForSession: response = .approveForSession
                case .decline: response = .decline(nil)
                }
                try await router().respondAgentRequest(thread: thread, requestId: request, response: response)
            },
            respondUserInput: { thread, request, text in
                try await router().respondAgentUserInput(thread: thread, requestId: request, text: text)
            },
            sendBotMessage: { bot, conversation, text in
                let router = try await router()
                try await MainActor.run {
                    guard let vm = router.botsViewModel else {
                        throw TitioNoticeActionError(reason: "the Bot runtime is unavailable")
                    }
                    _ = try vm.enqueueHostMessage(botID: bot, text: text, conversationID: conversation)
                }
            },
            acknowledgeBotAttention: { item in
                try botStore.acknowledgeAttention(id: item)
                await MainActor.run {
                    box.context?.router?.botsViewModel?.noteAttentionAcknowledged(item)
                    BotsViewModel.publishDestAttentionChanged()
                }
            },
            continueRun: { thread in
                _ = try await router().continueAgentRun(thread: thread)
            },
            rerunScheduledTask: { task in
                let router = try await router()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        guard let scheduler = router.scheduledTaskScheduler else {
                            continuation.resume(throwing: TitioNoticeActionError(reason: "scheduled tasks are not running"))
                            return
                        }
                        scheduler.runNow(taskID: task) { continuation.resume(with: $0) }
                    }
                }
            },
            acknowledgeActivity: { item in
                let router = try await router()
                _ = try await MainActor.run { try router.activityAcknowledge(params: ["item_id": .string(item)]) }
            },
            dismissNotification: { id in
                let router = try await router()
                try await MainActor.run { try router.notificationDismiss(id: id) }
            },
            markActivityViewed: { items in
                guard let router = try? await router() else { return }
                // One id per call: a finished-run or dismissed-notification check rejects a whole batch.
                await MainActor.run {
                    for item in items { _ = try? router.activitySetViewed(params: ["item_ids": .array([.string(item)]), "viewed": .bool(true)]) }
                }
            }
        )
    }

    /// Facts a run-terminal notice needs beyond the legacy inputs (§5).
    struct TitioRunFacts: Sendable {
        /// The Bot conversation this thread belongs to, if any.
        let botConversation: BotConversation?
        let bot: BotDefinition?
        let summary: String?
        let durationMs: Int?
        /// Titio's reply text for the direct reply banner.
        let finalMessageText: String?
        /// The scheduled task this run executes, if any.
        var scheduled: TitioScheduledRunFacts? = nil
    }

    /// A run started by a scheduled task: its failure is the task's
    /// `scheduledFailed` notice (with "Run again"), not a generic run failure.
    struct TitioScheduledRunFacts: Sendable, Equatable {
        let scheduledRunID: UUID
        let taskID: UUID
        let taskTitle: String?
    }

    /// The failure notice of a scheduled run, posted by the run hook the
    /// moment the run fails. Its key is the run's failure key, which is also
    /// what `ScheduledTaskRuntime.notifyFailure` ingests up to one scheduler
    /// tick later; posting the rich notice first means that later ingest is a
    /// no-op instead of being dropped against a generic run notice (a posted
    /// row is frozen), which lost the "Run again" card.
    nonisolated static func scheduledRunFailureFact(
        runId: AgentRunID,
        threadId: AgentThreadID,
        workspaceId: WorkspaceID?,
        workspaceName: String?,
        finalMessageId: String?,
        scheduled: TitioScheduledRunFacts,
        occurredAt: Date = Date()
    ) -> TitioNoticeFact {
        let rid = runId.value.uuidString
        let facts = TitioNoticeFacts(title: scheduled.taskTitle, workspaceName: workspaceName)
        return TitioNoticeFact(
            key: TitioNoticeIDs.scheduledFailure(scheduledRunId: scheduled.scheduledRunID.uuidString, agentRunId: rid),
            kind: .scheduledFailed,
            source: TitioNoticeSource(
                threadId: threadId.value.uuidString,
                runId: rid,
                workspaceId: workspaceId?.value.uuidString,
                scheduledTaskId: scheduled.taskID.uuidString.lowercased(),
                activityItemId: "run:\(rid.lowercased())",
                finalMessageId: finalMessageId
            ),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .scheduledFailed, facts: facts),
            occurredAt: occurredAt
        )
    }

    nonisolated static func titioRunFacts(
        runId: AgentRunID,
        threadId: AgentThreadID,
        finalMessageId: String?,
        db: SQLiteDB,
        botStore: BotStore,
        runRepo: AgentRunRepository
    ) -> TitioRunFacts {
        let conversation = (try? botStore.conversationLinked(to: threadId)) ?? nil
        let bot = conversation.flatMap { (try? botStore.get(id: $0.botID)) ?? nil }
        let result = (try? AgentRunResultRepository(db: db).get(runId: runId)) ?? nil
        // Timing probe, not a full row get: run finish stays off the
        // durable 10-column read (RunFinishProviderProbeTests).
        let timing = (try? runRepo.timing(of: runId)) ?? nil
        let durationMs = timing.flatMap { timing -> Int? in
            guard let finished = timing.finishedAt else { return nil }
            return max(0, Int(finished.timeIntervalSince(timing.startedAt) * 1_000))
        }
        let scheduledStore = ScheduledTaskStore(db: db)
        let scheduled = ((try? scheduledStore.activeRun(forThreadID: threadId)) ?? nil)
            .flatMap { run -> TitioScheduledRunFacts? in
                guard run.agentRunID == runId else { return nil }
                let task = (try? scheduledStore.get(id: run.taskID)) ?? nil
                return TitioScheduledRunFacts(scheduledRunID: run.id, taskID: run.taskID, taskTitle: task?.title)
            }
        var finalText: String?
        if bot?.handle.lowercased() == TitioBot.handle,
           let finalMessageId, let uuid = UUID(uuidString: finalMessageId) {
            finalText = (try? AgentMessageRepository(db: db).get(id: AgentMessageID(uuid)))??.content
        }
        return TitioRunFacts(
            botConversation: conversation,
            bot: bot,
            summary: result?.summary.map(BackgroundAwaitContinuation.strippingAwaitingMarker),
            durationMs: durationMs,
            finalMessageText: finalText,
            scheduled: scheduled
        )
    }

    /// Run outcomes (§2, §5). Returns true when the hub took the notice (or
    /// deliberately produced nothing); false keeps today's banner code.
    /// Policy checks (muted workspace, toggles, nested worker, side thread,
    /// user stop, pausedForUser) already ran before this branch.
    func ingestTitioRunOutcome(
        threadId: AgentThreadID,
        runId: AgentRunID,
        status: AgentRunStatus,
        workspaceId: WorkspaceID?,
        threadTitle: String?,
        finalMessageId: String?,
        facts: TitioRunFacts,
        legacy: RemoteCodeNotificationContent
    ) -> Bool {
        let outcome: TitioNoticeIDs.RunOutcome
        let kind: TitioNoticeKind
        switch status {
        case .completed: outcome = .completed; kind = .runCompleted
        case .failed: outcome = .failed; kind = .runFailed
        case .interrupted: outcome = .interrupted; kind = .runInterrupted
        case .cancelled, .pending, .running: return false
        }
        let rid = runId.value.uuidString
        let tid = threadId.value.uuidString
        if let conversation = facts.botConversation, let bot = facts.bot {
            if bot.handle.lowercased() == TitioBot.handle {
                // Titio's own replies: a direct reply banner, never a notice.
                // Its failures keep today's banner.
                guard status == .completed else { return false }
                if let text = facts.finalMessageText {
                    titioNoticeCenter.postDirectReplyBanner(
                        botID: bot.id,
                        conversationID: conversation.id,
                        runID: runId,
                        text: text,
                        messageID: finalMessageId.flatMap(UUID.init(uuidString:)).map(AgentMessageID.init)
                    )
                }
                return true
            }
            // Bot failures come only from the bot-attention projector.
            guard status == .completed else { return true }
            var botFacts = TitioNoticeFacts(
                workspaceName: workspaceId.flatMap { state.workspaces[$0]?.name },
                botName: bot.name,
                summary: facts.summary
            )
            botFacts.interruptionSuppressed = !bot.notificationsEnabled || router?.isBotConversationFocused(conversation.id) == true
            titioNoticeCenter.ingest(TitioNoticeFact(
                key: TitioNoticeIDs.botReply(runId: rid),
                kind: .botReply,
                source: TitioNoticeSource(
                    threadId: tid,
                    runId: rid,
                    workspaceId: workspaceId?.value.uuidString,
                    botId: bot.id.value.uuidString.lowercased(),
                    conversationId: conversation.id.value.uuidString.lowercased(),
                    finalMessageId: finalMessageId
                ),
                facts: botFacts,
                actions: TitioNoticeAction.defaultActions(kind: .botReply, facts: botFacts)
            ))
            return true
        }
        // Successes whose destination is focused are excluded; failures never are.
        if status == .failed, let scheduled = facts.scheduled {
            titioNoticeCenter.ingest(
                Self.scheduledRunFailureFact(
                    runId: runId,
                    threadId: threadId,
                    workspaceId: workspaceId,
                    workspaceName: workspaceId.flatMap { state.workspaces[$0]?.name },
                    finalMessageId: finalMessageId,
                    scheduled: scheduled
                ),
                legacy: TitioNoticeLegacyDelivery(content: legacy, pushes: true)
            )
            return true
        }
        var noticeFacts = TitioNoticeFacts(
            title: threadTitle,
            workspaceName: workspaceId.flatMap { state.workspaces[$0]?.name },
            summary: facts.summary,
            durationMs: status == .completed ? facts.durationMs : nil
        )
        noticeFacts.interruptionSuppressed = status == .completed && router?.isAgentThreadFocused(threadId) == true
        titioNoticeCenter.ingest(
            TitioNoticeFact(
                key: TitioNoticeIDs.runOutcome(runId: rid, outcome: outcome),
                kind: kind,
                source: TitioNoticeSource(
                    threadId: tid,
                    runId: rid,
                    workspaceId: workspaceId?.value.uuidString,
                    activityItemId: "run:\(rid.lowercased())",
                    finalMessageId: finalMessageId
                ),
                facts: noticeFacts,
                actions: TitioNoticeAction.defaultActions(kind: kind, facts: noticeFacts)
            ),
            legacy: status == .completed ? nil : TitioNoticeLegacyDelivery(content: legacy, pushes: true)
        )
        return true
    }
}

/// What a request notice needs (§5 "Requests"): the real request fields that
/// `postAgentUserActionPushIfNeeded` used to discard.
struct TitioRequestFacts: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case approval, userInput, manualAction }

    var kind: Kind
    var requestTitle: String?
    var detail: String?
    var prompt: String?
    var options: [String]?
    var isSecret: Bool
    var questionCount: Int
    /// Manual actions: the Bot that asked.
    var botName: String?
    /// The exact `actionTitle` today's code passes (the kill-switch path).
    var legacyActionTitle: String
    /// False when the provider cannot approve for the session: the card then
    /// offers no "Approve for session".
    var allowsSessionApproval: Bool
    /// `AssistantRequestKind` raw value of an approval (the copy's verb).
    var requestKind: String?

    init(
        kind: Kind,
        legacyActionTitle: String,
        requestTitle: String? = nil,
        detail: String? = nil,
        prompt: String? = nil,
        options: [String]? = nil,
        isSecret: Bool = false,
        questionCount: Int = 0,
        botName: String? = nil,
        allowsSessionApproval: Bool = true,
        requestKind: String? = nil
    ) {
        self.kind = kind
        self.requestTitle = requestTitle
        self.detail = detail
        self.prompt = prompt
        self.options = options
        self.isSecret = isSecret
        self.questionCount = questionCount
        self.botName = botName
        self.legacyActionTitle = legacyActionTitle
        self.allowsSessionApproval = allowsSessionApproval
        self.requestKind = requestKind
    }

    /// The card for this request (§2), without "Approve for session" when the
    /// provider does not support it.
    func actions(facts: TitioNoticeFacts) -> [TitioNoticeAction]? {
        let actions = TitioNoticeAction.defaultActions(kind: noticeKind, facts: facts)
        guard !allowsSessionApproval else { return actions }
        return actions?.filter { $0 != .approveSession }
    }

    var noticeKind: TitioNoticeKind {
        switch kind {
        case .approval: return .approval
        case .userInput: return .userInput
        case .manualAction: return .manualAction
        }
    }

    func noticeFacts(threadTitle: String?, workspaceName: String?) -> TitioNoticeFacts {
        TitioNoticeFacts(
            title: threadTitle,
            workspaceName: workspaceName,
            botName: botName,
            detail: detail,
            requestTitle: requestTitle,
            requestKind: requestKind,
            prompt: prompt,
            options: options,
            isSecret: isSecret ? true : nil,
            questionCount: questionCount > 0 ? questionCount : nil
        )
    }
}

extension AppContext {
    /// Replays the source event through the same classification as live intake.
    /// A checkpoint advances only after the canonical ledger row exists.
    func observeTitioAgentEvent(_ event: EventBus.Event) async -> Bool {
        guard case .object(let payload) = event.payload,
              let threadUUID = payload["thread_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let runUUID = payload["run_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return true }
        let thread = AgentThreadID(threadUUID)
        let run = AgentRunID(runUUID)
        let notices = TitioNoticeRepository(db: db)
        if event.kind == "agent.run.finished" {
            guard let status = payload["status"]?.stringValue.flatMap(AgentRunStatus.init(rawValue:)),
                  [.completed, .failed, .interrupted].contains(status),
                  (try? threadRepo.isEphemeral(of: thread)) != true else { return true }
            let inputs = await runFinishedNotificationInputs(runId: run, threadId: thread)
            // Titio's own replies have their existing direct banner path.
            if inputs.titio.bot?.handle.lowercased() == TitioBot.handle { return true }
            guard let content = RemoteCodeNotificationContent.threadOutcome(
                threadId: threadUUID.uuidString, runId: runUUID.uuidString,
                workspaceId: inputs.chrome?.workspaceId?.value.uuidString,
                title: inputs.chrome?.title, phase: status,
                isNestedWorker: inputs.isNestedWorker, finalMessageId: inputs.finalMessageId
            ) else { return true }
            _ = ingestTitioRunOutcome(threadId: thread, runId: run, status: status,
                workspaceId: inputs.chrome?.workspaceId, threadTitle: inputs.chrome?.title,
                finalMessageId: inputs.finalMessageId, facts: inputs.titio, legacy: content)
            if inputs.titio.bot != nil && status != .completed { return true }
            let key: String
            if inputs.titio.bot != nil { key = TitioNoticeIDs.botReply(runId: runUUID.uuidString) }
            else if status == .failed, inputs.titio.scheduled != nil {
                key = Self.scheduledRunFailureFact(runId: run, threadId: thread,
                    workspaceId: inputs.chrome?.workspaceId, workspaceName: nil,
                    finalMessageId: inputs.finalMessageId, scheduled: inputs.titio.scheduled!).key
            } else {
                key = TitioNoticeIDs.runOutcome(runId: runUUID.uuidString,
                    outcome: status == .completed ? .completed : status == .failed ? .failed : .interrupted)
            }
            return (try? notices.get(key: key)) != nil
        }
        guard let requestID = payload["request_id"]?.stringValue,
              ["agent.request.opened", "agent.user_input.requested"].contains(event.kind) else { return true }
        let approval = event.kind == "agent.request.opened"
        // Closed callbacks must not reappear as actionable questions after restart.
        guard let callback = try? providerPendingCallbackRepo.get(threadId: thread,
            requestId: requestID, kind: approval ? .approval : .userInput),
            callback.state == .pending,
            let active = try? runRepo.latestActive(for: thread), active.id == run else { return true }
        let facts: TitioRequestFacts
        if approval {
            facts = TitioRequestFacts(kind: .approval, legacyActionTitle: "Approval requested",
                requestTitle: payload["title"]?.stringValue, detail: payload["detail"]?.stringValue,
                allowsSessionApproval: payload["allows_session_approval"]?.boolValue ?? true,
                requestKind: payload["kind"]?.stringValue)
        } else {
            let questions: [JSONValue]
            if case .array(let values) = payload["questions"] { questions = values } else { questions = [] }
            let single = questions.count == 1 ? questions.first?.objectValue : nil
            let options: [String]
            if case .array(let values) = payload["options"], !values.isEmpty { options = values.compactMap(\.stringValue) }
            else if case .array(let values) = single?["options"] { options = values.compactMap { $0.objectValue?["label"]?.stringValue } }
            else { options = [] }
            let multiple = payload["allows_multiple_selection"]?.boolValue == true || single?["allows_multiple_selection"]?.boolValue == true
            let prompt = payload["prompt"]?.stringValue
            let secret = payload["is_secret"]?.boolValue == true
            facts = TitioRequestFacts(kind: .userInput,
                legacyActionTitle: secret ? "Secret input requested" : "Input requested",
                prompt: prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? prompt : single?["prompt"]?.stringValue,
                options: multiple ? nil : options, isSecret: secret, questionCount: questions.count)
        }
        let chrome = (try? threadRepo.listChrome(ids: [thread]))?[thread]
        guard let content = RemoteCodeNotificationContent.userActionNeeded(threadId: threadUUID.uuidString,
            workspaceId: chrome?.workspaceId?.value.uuidString, threadTitle: chrome?.title,
            actionTitle: facts.legacyActionTitle, requestId: requestID,
            isNestedWorker: isNestedAgentWorker(runId: run, threadId: thread)) else { return true }
        guard ingestTitioRequest(threadId: thread, runId: run, requestId: requestID,
            facts: facts, chrome: chrome, legacy: content) else { return true }
        return (try? notices.get(key: TitioNoticeIDs.threadAttention(
            threadId: threadUUID.uuidString, requestId: requestID, runId: runUUID.uuidString))) != nil
    }

    /// Requests (§5): approvals, input questions and manual actions. True when
    /// the hub took it; a Titio-linked thread keeps today's banner (Titio's own
    /// threads never produce a notice). Runs after the policy checks.
    func ingestTitioRequest(
        threadId: AgentThreadID,
        runId: AgentRunID,
        requestId: String,
        facts: TitioRequestFacts,
        chrome: AgentThreadRepository.ListChrome?,
        legacy: RemoteCodeNotificationContent
    ) -> Bool {
        let conversation = (try? botStore.conversationLinked(to: threadId)) ?? nil
        var request = facts
        if let conversation, let bot = (try? botStore.get(id: conversation.botID)) ?? nil {
            if bot.handle.lowercased() == TitioBot.handle { return false }
            if request.botName == nil { request.botName = bot.name }
        }
        let tid = threadId.value.uuidString
        let noticeFacts = request.noticeFacts(
            threadTitle: chrome?.title,
            workspaceName: chrome?.workspaceId.flatMap { state.workspaces[$0]?.name }
        )
        titioNoticeCenter.ingest(
            TitioNoticeFact(
                // One row per request instance (run id): a recycled provider
                // id never lands on, or is answered by, an older card.
                key: TitioNoticeIDs.threadAttention(threadId: tid, requestId: requestId, runId: runId.value.uuidString),
                kind: request.noticeKind,
                source: TitioNoticeSource(
                    threadId: tid,
                    runId: runId.value.uuidString,
                    requestId: requestId,
                    workspaceId: chrome?.workspaceId?.value.uuidString,
                    botId: conversation?.botID.value.uuidString.lowercased(),
                    conversationId: conversation?.id.value.uuidString.lowercased()
                ),
                facts: noticeFacts,
                actions: request.actions(facts: noticeFacts)
            ),
            legacy: TitioNoticeLegacyDelivery(content: legacy, pushes: true)
        )
        return true
    }
}

extension AppCommandRouter {
    /// Ensures Titio, its Notifications conversation and the linked thread
    /// (hub spec §8). Nil while the Bots view model is not up yet (launch):
    /// the hub keeps the rows pending and retries with backoff.
    func resolveTitioInbox(language: TitioNoticeLanguage) -> TitioInboxTarget? {
        guard let ctx = context, let vm = botsViewModel else { return nil }
        do {
            let bot = try TitioBot.ensure(store: ctx.botStore, appSupportDirectory: ctx.appSupportDirectory)
            let ensured = try TitioBot.ensureInboxConversation(
                store: ctx.botStore,
                notices: TitioNoticeRepository(db: ctx.db),
                bot: bot,
                language: language
            )
            let linked = try vm.ensureTitioInboxThread(bot: bot, conversation: ensured.conversation)
            vm.onTitioInboxSelected = { [weak ctx] _ in
                ctx?.titioNoticeCenter.markInboxRead()
                // The user is now reading the inbox: the pet stops talking over it.
                (NSApp?.delegate as? AppDelegate)?.petController?.reevaluateSpeech()
            }
            if ensured.created {
                EventBus.shared.publish(kind: .botConversationUpdated, payload: .object([
                    "method": .string("bot.conversation.create"),
                    "reason": .string("titio_inbox"),
                    "bot_id": .string(bot.id.value.uuidString.lowercased()),
                    "conversation_id": .string(linked.conversation.id.value.uuidString.lowercased()),
                ]))
            }
            return TitioInboxTarget(botID: bot.id, conversationID: linked.conversation.id, threadID: linked.thread.id)
        } catch {
            NSLog("RemoteCode: Titio inbox unavailable: \(error)")
            return nil
        }
    }

    /// A host-written inbox row (notice, act user row, result line, rewrite)
    /// repaints every open Agent App on that thread from the row itself,
    /// without reading SQLite on the MainActor.
    func projectTitioInboxMessage(_ message: AgentMessage) {
        botsViewModel?.deskAgentVM?.applyHostWrittenMessage(message)
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface else { continue }
            agent.viewModel.applyHostWrittenMessage(message)
        }
    }

    /// A cleared inbox message leaves every open Agent App on that thread
    /// (the in-process side of `agent.messages.removed`).
    func projectTitioInboxRemoval(_ ids: [AgentMessageID], threadID: AgentThreadID) {
        botsViewModel?.deskAgentVM?.applyHostRemovedMessages(ids, threadId: threadID)
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface else { continue }
            agent.viewModel.applyHostRemovedMessages(ids, threadId: threadID)
        }
    }

    /// The Mac desk shows the inbox and its window is key (§8 "viewing").
    func isTitioInboxViewed(_ conversationID: BotConversationID) -> Bool {
        guard let window = windowController?.window, window.isKeyWindow,
              NSApp?.isActive == true,
              windowController?.isShowingBotsContent == true,
              let vm = botsViewModel else { return false }
        return vm.isDeskShowing(conversationID: conversationID)
    }

    /// A Bot conversation the user is looking at on the Mac desk.
    func isBotConversationFocused(_ conversationID: BotConversationID) -> Bool {
        isTitioInboxViewed(conversationID)
    }

    /// A successful pet/terminal event whose destination is focused, by the
    /// same rule the pet uses (`PetAttentionFocusPolicy`, §2).
    func isFocusedPetSuccess(_ event: EventBus.Event) -> Bool {
        guard let ctx = context else { return false }
        let focusedSurfaceByWorkspace = ctx.state.workspaces.reduce(into: [WorkspaceID: SurfaceID]()) { result, entry in
            guard let paneID = entry.value.focusedPaneID,
                  let surfaceID = entry.value.layout.find(paneID: paneID)?.selectedSurfaceID else { return }
            result[entry.key] = surfaceID
        }
        let detached = Set(ctx.state.workspaces.keys.filter { windowController?.workspaceWindow(for: $0) != nil })
        let destination = PetAttentionFocusPolicy.resolveDestination(
            event: event,
            mainSelectedWorkspaceID: ctx.state.window.selectedWorkspaceID,
            focusedSurfaceByWorkspace: focusedSurfaceByWorkspace,
            detachedWorkspaceIDs: detached
        )
        let window = destination.detachedWorkspaceID.flatMap { windowController?.workspaceWindow(for: $0) }
            ?? windowController?.window
        return !PetAttentionFocusPolicy.shouldPersist(
            event: event,
            isAppActive: NSApp?.isActive == true,
            isDestinationWindowFocused: window?.isVisible == true && window?.isMiniaturized == false
                && window?.isKeyWindow == true,
            selectedWorkspaceID: destination.selectedWorkspaceID,
            focusedSurfaceID: destination.focusedSurfaceID
        )
    }

    /// The Agent App thread in the focused pane of the key main window (§2:
    /// a success there is not announced).
    func isAgentThreadFocused(_ threadID: AgentThreadID) -> Bool {
        guard let window = windowController?.window, window.isKeyWindow,
              NSApp?.isActive == true,
              windowController?.isShowingWorkspaceContent == true,
              let ctx = context,
              let workspaceID = ctx.state.window.selectedWorkspaceID,
              let workspace = ctx.state.workspaces[workspaceID],
              let pane = workspace.focusedPaneID,
              let surfaceID = workspace.layout.find(paneID: pane)?.selectedSurfaceID,
              let agent = SurfaceRegistry.shared.surface(surfaceID) as? AgentAppSurface else { return false }
        return agent.viewModel.selectedThreadId == threadID
    }
}
