import XCTest
@testable import AppShell
import CoreModel
import Persistence
import RemoteCodeTreaty
import SocketServer

@MainActor
final class AgentActivityServiceTests: XCTestCase {
    func test_botFailureHasOneActionAndDismissalClearsBothProjections() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let bot = try context.botStore.create(name: "Worker", title: "", description: "")
        let conversation = BotConversation(botID: bot.id, title: "Task", attentionState: .needsAttention, linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        let failed = try makeRun(context, thread: thread, status: .failed, at: 100)
        let receipt = BotAttentionItem(botID: bot.id, conversationID: conversation.id, kind: .blocked,
                                      title: "Run needs you", createdAt: Date(timeIntervalSince1970: 110))
        try context.botStore.upsertAttention(receipt)
        let activity = service(context)
        let runID = "run:\(failed.id.description)"
        XCTAssertEqual(try decodePage(activity.list(["section": .string("needs_you")])).items.map(\.id), [runID])
        _ = try activity.acknowledge(["item_id": .string(runID)])
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 0)
        XCTAssertTrue(try context.botStore.listAttention().isEmpty)
        XCTAssertNotEqual(try context.botStore.conversation(id: conversation.id)?.attentionState, .needsAttention)
        _ = try activity.acknowledge(["item_ids": .array([.string(runID)]), "acknowledged": .bool(false)])
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 1)
        try context.botStore.acknowledgeAttention(id: receipt.id)
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 0, "dismissing from Bots must not reveal the same failure again in Activity")
        XCTAssertEqual(try context.runRepo.get(id: failed.id)?.status, .failed)
    }

    func test_resolvedApprovalNotificationDoesNotReappearAsANewRequest() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let run = try makeRun(context, thread: thread, status: .running, at: 100)
        try context.providerPendingCallbackRepo.record(threadId: thread.id, request: pendingRequest("approval"))
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "approval-notice", title: "Approval", body: "{\"thread_id\":\"\(thread.id.description)\",\"request_id\":\"approval\"}",
            category: PetNotificationCategory.agentAttention.rawValue
        ))
        let activity = service(context, activeRunID: run.id)
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 1)
        try context.providerPendingCallbackRepo.resolve(threadId: thread.id, requestId: "approval", kind: .approval, state: .approved)
        let page = try decodePage(activity.list([:]))
        XCTAssertEqual(page.counts.needsYou, 0)
        XCTAssertEqual(page.counts.running, 1)
        XCTAssertFalse(page.items.contains { $0.notificationID == "approval-notice" })
    }

    func test_retriedBotFailureDoesNotAskForAttentionWhileTheBotIsWorking() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let bot = try context.botStore.create(name: "Worker", title: "", description: "")
        let conversation = BotConversation(botID: bot.id, title: "Task", attentionState: .needsAttention, linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        _ = try makeRun(context, thread: thread, status: .failed, at: 100)
        try context.botStore.upsertAttention(BotAttentionItem(
            botID: bot.id, conversationID: conversation.id, kind: .blocked,
            title: "Run needs you", detail: "The previous run failed.", createdAt: Date(timeIntervalSince1970: 110)
        ))
        let retry = try makeRun(context, thread: thread, status: .running, at: 200)

        let page = try decodePage(service(context, activeRunID: retry.id).list([:]))
        XCTAssertEqual(page.counts.running, 1)
        XCTAssertEqual(page.counts.needsYou, 0, "a retry supersedes the old Bot failure as well as its run result")
        XCTAssertTrue(try context.botStore.listAttention().isEmpty)
        XCTAssertNotEqual(try context.botStore.conversation(id: conversation.id)?.attentionState, .needsAttention)
    }

    func test_botQuestionNeedsAReplyAndClearsOnlyAfterNewUserInput() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let bot = try context.botStore.create(name: "Worker", title: "", description: "")
        let conversation = BotConversation(botID: bot.id, title: "Task", attentionState: .needsAttention, linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        let run = try makeRun(context, thread: thread, status: .running, at: 100)
        let question = BotAttentionItem(botID: bot.id, conversationID: conversation.id, kind: .question,
                                        title: "Reply requested", detail: "Which destination?", createdAt: Date(timeIntervalSince1970: 110))
        try context.botStore.upsertAttention(question)
        let activity = service(context, activeRunID: run.id)
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 1)
        try context.messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "Waiting for your choice.", createdAt: Date(timeIntervalSince1970: 120)))
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 1, "assistant activity is not a user answer")
        try context.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "Use staging.", createdAt: Date(timeIntervalSince1970: 130)))
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 0)
        XCTAssertTrue(try BotStore(db: context.db).listAttention().isEmpty, "reopening must not resurrect an answered question")
        XCTAssertNotEqual(try context.botStore.conversation(id: conversation.id)?.attentionState, .needsAttention)
    }

    func test_acknowledgingFailurePreservesFailedRunAndRemovesNeedsYou() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let run = try makeRun(context, thread: thread, status: .failed, at: 100)
        try insertResult(context, runID: run.id)
        XCTAssertEqual(try decodePage(service(context).list([:])).counts.needsYou, 1)

        let response = try service(context).acknowledge(["item_id": .string("run:\(run.id.description)")])
        XCTAssertEqual(response.objectValue?["acknowledged"]?.boolValue, true)
        XCTAssertEqual(try context.runRepo.get(id: run.id)?.status, .failed)
        let page = try decodePage(service(context).list([:]))
        XCTAssertEqual(page.counts.finished, 1)
        XCTAssertEqual(page.counts.needsYou, 0)
        XCTAssertEqual(page.items.first?.state, .failed)
    }

    func test_batchAcknowledgeClearsFailuresBotRequestsAndConflictsSkipsCompletedAndReopenRestoresNeedsYou() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let failed = try makeRun(context, thread: thread, status: .failed, at: 100)
        let completed = try makeRun(context, thread: try makeThread(context), status: .completed, at: 200)
        let bot = try context.botStore.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let conversation = BotConversation(botID: bot.id, title: "Deploy check", attentionState: .needsAttention)
        try context.botStore.upsertConversation(conversation)
        let attention = BotAttentionItem(botID: bot.id, conversationID: conversation.id, kind: .question, title: "private question", detail: "token=private")
        try context.botStore.upsertAttention(attention)
        try NotificationRepository(db: context.db).insert(AppNotification(id: "conflict", title: "private file", category: PetNotificationCategory.fileConflict.rawValue))
        let activity = service(context)

        let before = try decodePage(activity.list(["section": .string("needs_you")]))
        XCTAssertEqual(before.counts.needsYou, 3)
        let botItem = try XCTUnwrap(before.items.first { $0.id.hasPrefix("bot-attention:") })
        XCTAssertEqual(botItem.originLabel, "Bot conversation: Deploy check", "a bot request must say which conversation is waiting")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(before), as: UTF8.self).contains("private"))

        let failedID = "run:\(failed.id.description)"
        let ids = [failedID, botItem.id, "run:\(completed.id.description)", "notification:conflict"]
        let response = try activity.acknowledge(["item_ids": .array(ids.map(JSONValue.string))])
        XCTAssertEqual(response.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue), [failedID, botItem.id, "notification:conflict"],
                       "a completed run has nothing to acknowledge")
        let cleared = try decodePage(activity.list([:]))
        XCTAssertEqual(cleared.counts.needsYou, 0, "Clear all leaves nothing in Needs you (owner, 2026-10-14)")
        XCTAssertEqual(cleared.counts.finished, 3, "clearing must never remove a result from history; the conflict lands in Finished")
        XCTAssertEqual(cleared.items.first { $0.runID == failed.id.value }?.state, .failed)
        XCTAssertNotNil(try context.botStore.listAttention(includeAcknowledged: true).first { $0.id == attention.id }?.acknowledgedAt)
        XCTAssertNil(try NotificationRepository(db: context.db).list(workspaceId: nil, limit: 10).first { $0.id == "conflict" }?.readAt,
                     "clearing the inbox row must not mark the conflict itself resolved")

        let reopened = try activity.acknowledge(["item_ids": .array([.string(failedID), .string(botItem.id), .string("notification:conflict")]), "acknowledged": .bool(false)])
        XCTAssertEqual(reopened.objectValue?["acknowledged"]?.boolValue, false)
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 3, "Undo must put every cleared item back in Needs you")
    }

    func test_batchAcknowledgeRejectsUnknownKindsAndMalformedBatches() throws {
        let context = try makeContext()
        let activity = service(context)
        XCTAssertThrowsError(try activity.acknowledge(["item_ids": .array([.string("project-script:surface:1")])]),
                             "a live script is not a Needs you item")
        XCTAssertEqual(try activity.acknowledge(["item_ids": .array([.string("request:thread:gone")])])
                        .objectValue?["updated_ids"]?.arrayValue?.count, 0,
                       "a request another client already resolved is skipped, not an error")
        XCTAssertThrowsError(try activity.acknowledge(["item_ids": .array([.string("notification:a"), .string("notification:a")])]))
        XCTAssertThrowsError(try activity.acknowledge(["item_ids": .array((0...200).map { .string("notification:\($0)") })]))
        XCTAssertThrowsError(try activity.acknowledge([:]))
        XCTAssertEqual(try activity.acknowledge(["item_ids": .array([])]).objectValue?["updated_ids"]?.arrayValue?.count, 0)
    }

    func test_bulkPageReturnsAWholeFilterInOnePassAndStaysCapped() throws {
        let context = try makeContext()
        let repository = NotificationRepository(db: context.db)
        for index in 0..<120 {
            try repository.insert(AppNotification(id: "note-\(index)", title: "safe", category: PetNotificationCategory.gitCompleted.rawValue, createdAt: Date(timeIntervalSince1970: Double(1_000 + index))))
        }
        let activity = service(context)
        XCTAssertEqual(try decodePage(activity.list(["section": .string("finished")])).items.count, 50, "an ordinary page stays small")
        let bulk = try decodePage(activity.list(["section": .string("finished"), "limit": .number(500)]))
        XCTAssertEqual(bulk.items.count, ActivityService.resultsLimit, "Results keeps only the newest 99 finished items; the rest stay in the database")
        XCTAssertNil(bulk.nextCursor)
        XCTAssertEqual(bulk.items.first?.id, "notification:note-119", "the larger page keeps newest-first order")
        // Failures need action, so the Results cap never drops them; the page limit still bounds the response.
        for index in 120..<620 {
            try repository.insert(AppNotification(id: "note-\(index)", title: "safe", category: PetNotificationCategory.gitFailed.rawValue, createdAt: Date(timeIntervalSince1970: Double(1_000 + index))))
        }
        let capped = try decodePage(activity.list(["section": .string("finished"), "limit": .number(5_000)]))
        XCTAssertEqual(capped.items.count, 500, "the response size stays bounded whatever a client asks for")
        XCTAssertNotNil(capped.nextCursor)
    }

    func test_resultsKeepNewest99CompletedAndNeverDropAnItemThatNeedsAction() throws {
        // WHY: Results is a feed the owner reads, not an archive; 548 finished rows buried the
        // list. Only done items are capped, so a failure still waiting for the owner stays visible.
        let context = try makeContext()
        let failed = try makeRun(context, thread: try makeThread(context), status: .failed, at: 1)
        var completedIDs: [String] = []
        for index in 0..<120 {
            let run = try makeRun(context, thread: try makeThread(context), status: .completed, at: Double(1_000 + index))
            completedIDs.append("run:\(run.id.description)")
        }
        let activity = service(context)
        let page = try decodePage(activity.list(["section": .string("finished"), "limit": .number(500)]))
        let ids = Set(page.items.map(\.id))
        XCTAssertTrue(ids.contains("run:\(failed.id.description)"), "a failure that needs action is never dropped, however old")
        XCTAssertEqual(page.items.filter { $0.state == .completed }.count, ActivityService.resultsLimit)
        XCTAssertEqual(page.counts.finished, ActivityService.resultsLimit + 1, "the count matches what Results lists")
        XCTAssertEqual(page.items.first { $0.state == .completed }?.id, completedIDs.last, "the newest completed run is kept")
        XCTAssertFalse(ids.contains(completedIDs[0]), "the oldest completed run is dropped from the view")
        XCTAssertNotNil(try AgentRunRepository(db: context.db).get(id: AgentRunID(UUID(uuidString: String(completedIDs[0].dropFirst(4)))!)),
                        "the cap is a view limit: the run row stays in the database")
    }

    func test_durableRunWithoutCanonicalRuntimeIdentityIsNotReportedRunning() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let run = try makeRun(context, thread: thread, status: .running, at: 100)
        let page = try decodePage(service(context).list([:]))
        XCTAssertEqual(page.counts.running, 0)
        XCTAssertEqual(page.items.first { $0.runID == run.id.value }?.state, .needsYou)
    }

    func test_pendingCallbackBlocksCanonicalRunFromRunningCountAndStaleCallbackExpires() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let running = try makeRun(context, thread: thread, status: .running, at: 100)
        try context.providerPendingCallbackRepo.record(threadId: thread.id, request: pendingRequest("approval"))
        try context.providerPendingCallbackRepo.record(threadId: thread.id, request: pendingRequest("stale"))
        try context.providerPendingCallbackRepo.markStale(threadId: thread.id, requestId: "stale", kind: .approval, reason: "run ended")
        let activity = service(context, activeRunID: running.id)

        let page = try decodePage(activity.list([:]))
        XCTAssertEqual(page.counts.running, 0)
        XCTAssertTrue(page.items.contains { $0.runID == running.id.value && $0.blocking })
        XCTAssertTrue(page.items.contains { $0.requestID == "approval" && $0.state == .waitingApproval })
        XCTAssertTrue(page.items.contains { $0.requestID == "stale" && $0.state == .expired && !$0.needsAction })
        XCTAssertNil(page.items.first(where: { $0.requestID == "stale" })?.runID)
        let retry = try makeRun(context, thread: thread, status: .running, at: 200)
        let retried = try decodePage(service(context, activeRunID: retry.id).list([:]))
        XCTAssertEqual(retried.counts.needsYou, 0, "an older callback cannot block a new run")
        XCTAssertEqual(retried.counts.running, 1)
    }

    func test_notificationKeepsCustomIDUsesSafeTypeAndDedupesOnlyProvenRunOrRequest() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let run = try makeRun(context, thread: thread, status: .completed, at: 100)
        try insertResult(context, runID: run.id)
        let notifications = NotificationRepository(db: context.db)
        try notifications.insert(AppNotification(id: "external:custom", title: "PRIVATE title", body: "PRIVATE body", category: PetNotificationCategory.gitCompleted.rawValue, createdAt: Date(timeIntervalSince1970: 500)))
        try notifications.insert(AppNotification(id: "duplicate-run", title: "ignored", body: "{\"run_id\":\"\(run.id.description)\"}", category: PetNotificationCategory.gitCompleted.rawValue))
        try notifications.insert(AppNotification(id: "duplicate-request", title: "ignored", body: "{\"request_id\":\"known-request\",\"thread_id\":\"\(thread.id.description)\"}", category: PetNotificationCategory.gitCompleted.rawValue))
        try context.providerPendingCallbackRepo.record(threadId: thread.id, request: pendingRequest("known-request"))

        let page = try decodePage(service(context, activeRunID: run.id).list([:]))
        let notification = try XCTUnwrap(page.items.first { $0.id == "notification:external:custom" })
        XCTAssertEqual(notification.title, PetNotificationCategory.gitCompleted.presentation.title)
        XCTAssertEqual(notification.notificationID, "external:custom")
        XCTAssertNil(notification.summary)
        XCTAssertFalse(page.items.contains { $0.id == "notification:duplicate-run" })
        XCTAssertFalse(page.items.contains { $0.id == "notification:duplicate-request" })
        let serialized = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertFalse(serialized.contains("PRIVATE"))
    }

    func test_projectScriptRecorderSummaryKeepsCanonicalOutcomeAndExitCodeOnly() throws {
        let context = try makeContext()
        let workspaceID = WorkspaceID()
        let surfaceID = SurfaceID()
        let event = EventBus.Event(seq: 42, kind: "project.script.finished", payload: .object([
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "result": .string("failure"),
            "exit_code": .number(7),
            "name": .string("PRIVATE script"),
            "output": .string("PRIVATE transcript")
        ]), ts: 100)
        let recorded = try XCTUnwrap(try PetTerminalNotificationRecorder(repository: NotificationRepository(db: context.db)).record(event: event))
        let item = try XCTUnwrap(decodePage(service(context).list([:])).items.first { $0.notificationID == recorded.id })
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.summary, "Project script failed (exit code 7)")
        XCTAssertFalse(item.summary?.contains("PRIVATE") ?? true)
    }

    func test_scopedCountsAndFractionalCursorFreezeNewArrivals() throws {
        let context = try makeContext()
        let workspaceA = WorkspaceID()
        let workspaceB = WorkspaceID()
        let firstThread = try makeThread(context, workspace: workspaceA)
        let secondThread = try makeThread(context, workspace: workspaceB)
        _ = try makeRun(context, thread: firstThread, status: .completed, at: 100.125)
        _ = try makeRun(context, thread: try makeThread(context, workspace: workspaceA), status: .failed, at: 100.875)
        _ = try makeRun(context, thread: secondThread, status: .completed, at: 100.5)
        let activity = service(context)
        let first = try decodePage(activity.list(["workspace_id": .string(workspaceA.description), "section": .string("finished"), "limit": .number(1)]))
        XCTAssertEqual(first.counts.finished, 2)
        XCTAssertEqual(first.items.count, 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        _ = try makeRun(context, thread: firstThread, status: .completed, at: Date().addingTimeInterval(60).timeIntervalSince1970)
        let next = try decodePage(activity.list(["workspace_id": .string(workspaceA.description), "section": .string("finished"), "limit": .number(1), "cursor": .string(cursor)]))
        XCTAssertEqual(next.counts.finished, 2)
        XCTAssertEqual(next.items.count, 1)
        XCTAssertNotEqual(next.items.first?.id, first.items.first?.id)
    }

    func test_justFinishedListsOnlyUnopenedFinishedRunsAndMatchesItsCount() throws {
        // WHY: the Just finished tab lets the user see what recently finished; a run
        // leaves it once opened, and the tab count must equal what it lists.
        let context = try makeContext()
        let seen = try makeRun(context, thread: try makeThread(context), status: .completed, at: 100)
        let unseen = try makeRun(context, thread: try makeThread(context), status: .failed, at: 200)
        _ = try makeRun(context, thread: try makeThread(context), status: .running, at: 300)
        _ = try service(context).setViewed(["item_ids": .array([.string("run:\(seen.id.description)")]), "viewed": .bool(true)])

        let page = try decodePage(service(context).list(["section": .string("just_finished")]))
        XCTAssertEqual(page.items.map(\.id), ["run:\(unseen.id.description)"], "not the opened run, not the running one")
        XCTAssertEqual(page.counts.newResults, page.items.count)
        XCTAssertEqual(try decodePage(service(context).list(["section": .string("finished")])).items.count, 2, "Results still keeps both")
    }

    func test_legacyTerminalRunViewedCreatesResultWithoutSummaryAndRestoreCanClear() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let run = try makeRun(context, thread: thread, status: .completed, at: 100)
        let runItemID = "run:\(run.id.description)"

        let viewed = try service(context).setViewed(["item_ids": .array([.string(runItemID)]), "viewed": .bool(true)])
        XCTAssertEqual(viewed.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue), [runItemID])
        let row = try XCTUnwrap(AgentRunResultRepository(db: context.db).get(runId: run.id))
        XCTAssertNotNil(row.viewedAt)
        XCTAssertNil(row.summary)

        _ = try service(context).setViewed([
            "item_ids": .array([.string(runItemID)]), "viewed": .bool(false),
            "restore_viewed_at": .object([runItemID: .null])
        ])
        XCTAssertNil(try AgentRunResultRepository(db: context.db).get(runId: run.id)?.viewedAt)
    }

    func test_checkpointEvidenceLinksOnlyByExactRunID() throws {
        let context = try makeContext()
        let thread = try makeThread(context)
        let first = try makeRun(context, thread: thread, status: .completed, at: 100)
        let otherThread = try makeThread(context)
        let second = try makeRun(context, thread: otherThread, status: .completed, at: 101)
        try insertCheckpoint(context, runID: first.id, threadID: thread.id, file: "first.swift", sequence: 1, turnID: "provider-turn-a")
        try insertCheckpoint(context, runID: second.id, threadID: otherThread.id, file: "second.swift", sequence: 2, turnID: "provider-turn-b")

        let page = try decodePage(service(context).list([:]))
        let firstItem = try XCTUnwrap(page.items.first { $0.runID == first.id.value })
        let secondItem = try XCTUnwrap(page.items.first { $0.runID == second.id.value })
        XCTAssertEqual(firstItem.checkpointTurnCount, 1)
        XCTAssertEqual(firstItem.changedFiles, ["first.swift"])
        XCTAssertNil(firstItem.checkpointID)
        XCTAssertEqual(secondItem.checkpointTurnCount, 2)
        XCTAssertEqual(secondItem.changedFiles, ["second.swift"])
        XCTAssertNil(secondItem.checkpointID)
    }

    func test_notificationViewedDoesNotCallFailureAcknowledgment() throws {
        let context = try makeContext()
        try NotificationRepository(db: context.db).insert(AppNotification(id: "custom-note", title: "safe", category: PetNotificationCategory.gitCompleted.rawValue))
        let response = try service(context).setViewed(["item_ids": .array([.string("notification:custom-note")]), "viewed": .bool(true)])
        XCTAssertEqual(response.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue), ["notification:custom-note"])
        let note = try XCTUnwrap(NotificationRepository(db: context.db).list().first { $0.id == "custom-note" })
        XCTAssertNil(note.readAt, "Viewing Activity does not resolve the canonical notification.")
        XCTAssertNotNil(try decodePage(service(context).list([:])).items.first { $0.id == "notification:custom-note" }?.viewedAt)
    }

    func test_operationFailureViewedAndUndoNeverAcknowledgeWhileExplicitAckPreservesHistory() throws {
        let context = try makeContext()
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(id: "git-failure", title: "private command", body: "{\"activity_summary\":\"Operation failed: password=private\"}", category: PetNotificationCategory.gitFailed.rawValue))
        let activity = service(context)
        let storedOperation = try XCTUnwrap(decodePage(activity.list([:])).items.first { $0.id == "notification:git-failure" })
        XCTAssertEqual(storedOperation.summary, "Operation failed: [REDACTED]")
        let id = "notification:git-failure"
        let initial = try decodePage(activity.list([:]))
        XCTAssertEqual(initial.counts.finished, 1)
        XCTAssertEqual(initial.counts.needsYou, 1)
        XCTAssertEqual(initial.counts.newResults, 1)
        _ = try activity.setViewed(["item_ids": .array([.string(id)]), "viewed": .bool(true)])
        let seen = try decodePage(activity.list([:]))
        XCTAssertEqual(seen.counts.needsYou, 1, "Reading must not resolve a failure.")
        XCTAssertEqual(seen.counts.newResults, 0)
        XCTAssertEqual(seen.items.first?.state, .failed)
        _ = try activity.setViewed(["item_ids": .array([.string(id)]), "viewed": .bool(false), "restore_viewed_at": .object([id: .null])])
        XCTAssertEqual(try decodePage(activity.list([:])).counts.newResults, 1)
        _ = try activity.acknowledge(["item_id": .string(id)])
        let acknowledged = try decodePage(activity.list([:]))
        XCTAssertEqual(acknowledged.counts.needsYou, 0)
        XCTAssertEqual(acknowledged.counts.finished, 1)
        XCTAssertEqual(acknowledged.items.first?.state, .failed)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(acknowledged), as: UTF8.self).contains("private"))
    }

    func test_botNotificationMetadataRoutesExactBotWithoutLinkedRun() throws {
        let context = try makeContext()
        let botID = UUID()
        let notificationID = "bot-notification"
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: notificationID, title: "private title", body: "private body", category: "RemoteCodeThreadUpdate"
        ))
        try BotAttentionNotificationMetadataStore(db: context.db).record(BotAttentionNotificationMetadata(
            notificationID: notificationID, profileID: UUID().uuidString, hostID: UUID().uuidString,
            attentionItemID: UUID().uuidString, botID: botID.uuidString, source: "test"
        ))
        let item = try XCTUnwrap(decodePage(service(context).list([:])).items.first { $0.id == "notification:\(notificationID)" })
        XCTAssertEqual(item.botID, botID)
        XCTAssertNil(item.runID)
        XCTAssertNil(item.threadID)
        XCTAssertNil(item.conversationID)
    }

    func test_botLinkedRunCarriesBotAndConversationSoActivityOpensTheDesk() throws {
        // WHY: a bot Desk thread has no workspace. Without its bot on the row, Activity sent it
        // to openAgentThread, which can only throw ("CoreModel.LayoutError error 0").
        let context = try makeContext()
        let thread = try makeThread(context)
        let bot = try context.botStore.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let conversation = BotConversation(botID: bot.id, title: "oi", linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        let run = try makeRun(context, thread: thread, status: .completed, at: 100)
        let unlinked = try makeRun(context, thread: try makeThread(context), status: .completed, at: 200)

        let items = try decodePage(service(context).list([:])).items
        let item = try XCTUnwrap(items.first { $0.id == "run:\(run.id.description)" })
        XCTAssertEqual(item.botID, bot.id.value)
        XCTAssertEqual(item.conversationID, conversation.id.value)
        XCTAssertEqual(item.threadID, thread.id.value, "the row still names its thread for the embedded transcript")
        let plain = try XCTUnwrap(items.first { $0.id == "run:\(unlinked.id.description)" })
        XCTAssertNil(plain.botID, "a thread no bot owns must keep the workspace route")
        XCTAssertNil(plain.conversationID)
    }

    func test_unknownNotificationRemainsVisibleWithSafeCanonicalTitle() throws {
        let context = try makeContext()
        try NotificationRepository(db: context.db).insert(AppNotification(id: "thread-update", title: "private title", body: "private body", category: "RemoteCodeThreadUpdate"))
        let item = try XCTUnwrap(decodePage(service(context).list([:])).items.first { $0.id == "notification:thread-update" })
        XCTAssertEqual(item.title, "Notification")
        XCTAssertFalse(item.needsAction)
        XCTAssertNil(item.summary)
    }

    func test_fileConflictReadAtDoesNotBecomeActivitySeenState() throws {
        let context = try makeContext()
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(id: "resolved-conflict", title: "safe", category: PetNotificationCategory.fileConflict.rawValue, readAt: Date(timeIntervalSince1970: 100)))
        let item = try XCTUnwrap(decodePage(service(context).list([:])).items.first { $0.id == "notification:resolved-conflict" })
        XCTAssertNil(item.viewedAt, "Canonical conflict resolution must not mark Activity result as seen.")
        XCTAssertEqual(item.state, .completed)
        XCTAssertFalse(item.needsAction)
    }

    func test_unresolvedFileConflictReadViaActivityRemainsNeedsYou() throws {
        let context = try makeContext()
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(id: "unresolved-conflict", title: "safe", category: PetNotificationCategory.fileConflict.rawValue))
        let activity = service(context)
        _ = try activity.setViewed(["item_ids": .array([.string("notification:unresolved-conflict")]), "viewed": .bool(true)])
        let item = try XCTUnwrap(decodePage(activity.list([:])).items.first { $0.id == "notification:unresolved-conflict" })
        XCTAssertEqual(item.state, .needsYou)
        XCTAssertTrue(item.needsAction)
    }

    func test_resurfacedNotificationStartsNewActivityOccurrence() throws {
        let context = try makeContext()
        let repository = NotificationRepository(db: context.db)
        let old = AppNotification(id: "resurface", title: "safe", category: PetNotificationCategory.gitFailed.rawValue)
        try repository.insert(old)
        let activity = service(context)
        _ = try activity.setViewed(["item_ids": .array([.string("notification:resurface")]), "viewed": .bool(true)])
        XCTAssertNotNil(try decodePage(activity.list([:])).items.first { $0.id == "notification:resurface" }?.viewedAt)
        try repository.resurface(AppNotification(id: "resurface", title: "safe", category: PetNotificationCategory.gitFailed.rawValue, createdAt: Date().addingTimeInterval(10)))
        XCTAssertNil(try decodePage(activity.list([:])).items.first { $0.id == "notification:resurface" }?.viewedAt)
    }

    func test_fileConflictSurvivesReadButClearingLeavesNeedsYou() throws {
        let context = try makeContext()
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(id: "conflict", title: "private file", category: PetNotificationCategory.fileConflict.rawValue))
        let activity = service(context)
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 1)
        _ = try activity.setViewed(["item_ids": .array([.string("notification:conflict")]), "viewed": .bool(true)])
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 1, "Viewing conflict must not resolve canonical conflict state.")
        _ = try activity.acknowledge(["item_id": .string("notification:conflict")])
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 0, "an explicit clear empties Needs you")
        try repository.dismiss(id: "conflict")
        XCTAssertEqual(try decodePage(activity.list([:])).counts.needsYou, 0)
    }

    func test_clearingRequestsAndOrphanedRunsEmptiesNeedsYouSurvivesRunEndAndUndoRestores() throws {
        // WHY: the owner (2026-10-14) saw an expired "Approval needed" survive Clear all.
        // Every Needs you kind must clear, and a cleared live approval must not come
        // back when its run ends and the item id switches to the expired form.
        let context = try makeContext()
        let thread = try makeThread(context)
        let running = try makeRun(context, thread: thread, status: .running, at: 100)
        let orphanThread = try makeThread(context)
        let orphan = try makeRun(context, thread: orphanThread, status: .running, at: 50)
        try context.providerPendingCallbackRepo.record(threadId: thread.id, request: pendingRequest("approval"))
        try context.providerPendingCallbackRepo.record(threadId: thread.id, request: pendingRequest("stale"))
        try context.providerPendingCallbackRepo.markStale(threadId: thread.id, requestId: "stale", kind: .approval, reason: "run ended")
        let live = ActivityService(context: context, activeRunIDProvider: { $0 == thread.id ? running.id : nil })

        let before = try decodePage(live.list(["section": .string("needs_you")]))
        let ids = before.items.map(\.id)
        XCTAssertEqual(Set(ids), [
            "request:\(running.id.description):approval", "run:\(orphan.id.description)"
        ])
        let response = try live.acknowledge(["item_ids": .array(ids.map(JSONValue.string))])
        XCTAssertEqual(response.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue), ids)
        XCTAssertEqual(try decodePage(live.list([:])).counts.needsYou, 0, "Clear all leaves nothing behind")
        XCTAssertEqual(try context.providerPendingCallbackRepo.list(states: [.pending]).map(\.requestId), ["approval"],
                       "clearing the inbox never answers the approval; its thread still holds it")

        let end = try context.db.prepare("UPDATE agent_runs SET status = 'completed' WHERE id = ?;")
        try end.bind(1, running.id.description)
        _ = try end.step()
        end.reset()
        let ended = try decodePage(service(context).list([:]))
        XCTAssertEqual(ended.items.first { $0.requestID == "approval" }?.state, .expired, "its run ended, so it reads as expired")
        XCTAssertEqual(ended.counts.needsYou, 0,
                       "the cleared approval stays cleared once its run ends and its item id changes")

        _ = try service(context).acknowledge(["item_ids": .array([
            .string("request:\(thread.id.description):approval"), .string("request:\(thread.id.description):stale"),
            .string("run:\(orphan.id.description)")
        ]), "acknowledged": .bool(false)])
        XCTAssertEqual(try decodePage(service(context).list([:])).counts.needsYou, 1, "Undo restores the orphan alert, but cannot make expired requests actionable")
    }

    func test_conversationShowsOnlyItsLatestResultAndALaterRunSettlesAnOldFailure() throws {
        // WHY: the owner (2026-10-19) saw Needs you 32 / Finished 841 for a few dozen
        // conversations. Activity is an inbox: one row per conversation result, and a
        // failure the user already retried no longer needs them.
        let context = try makeContext()
        let retried = try makeThread(context)
        let oldFailure = try makeRun(context, thread: retried, status: .failed, at: 100)
        let retry = try makeRun(context, thread: retried, status: .completed, at: 200)
        let stillFailing = try makeThread(context)
        let earlierPass = try makeRun(context, thread: stillFailing, status: .completed, at: 100)
        let latestFailure = try makeRun(context, thread: stillFailing, status: .failed, at: 300)
        let rerunning = try makeThread(context)
        let failedBeforeRerun = try makeRun(context, thread: rerunning, status: .failed, at: 100)
        let rerun = try makeRun(context, thread: rerunning, status: .running, at: 400)

        let page = try decodePage(service(context, activeRunID: rerun.id).list([:]))
        let runIDs = Set(page.items.compactMap(\.runID))
        XCTAssertTrue(runIDs.contains(retry.id.value))
        XCTAssertFalse(runIDs.contains(oldFailure.id.value), "a retried failure is history, not a result")
        XCTAssertFalse(runIDs.contains(earlierPass.id.value), "only the latest result of a conversation is listed")
        XCTAssertEqual(page.counts.finished, 3)
        XCTAssertEqual(Set(page.items.filter(\.needsAction).compactMap(\.runID)), [latestFailure.id.value],
                       "a failure whose conversation is running again no longer needs you")
        XCTAssertTrue(runIDs.contains(failedBeforeRerun.id.value), "its result still shows until the new run finishes")
    }

    func test_unfilteredListAlwaysReturnsWorkspaceCountsPerWorkspace() throws {
        let context = try makeContext()
        let workspaceA = WorkspaceID()
        let workspaceB = WorkspaceID()
        _ = try makeRun(context, thread: try makeThread(context, workspace: workspaceA), status: .completed, at: 100)
        _ = try makeRun(context, thread: try makeThread(context, workspace: workspaceA), status: .failed, at: 101)
        _ = try makeRun(context, thread: try makeThread(context, workspace: workspaceB), status: .completed, at: 102)
        let page = try decodePage(service(context).list(["section": .string("running")]))
        let byWorkspace = try XCTUnwrap(page.workspaceCounts, "host must always return workspace_counts")
        XCTAssertEqual(byWorkspace[workspaceA.value.uuidString]?.finished, 2)
        XCTAssertEqual(byWorkspace[workspaceB.value.uuidString]?.finished, 1)
    }

    private func makeContext() throws -> AppContext {
        try AppContext(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "activity-" + UUID().uuidString)
    }
    private func makeThread(_ context: AppContext, workspace: WorkspaceID? = nil) throws -> AgentThread {
        let thread = AgentThread(workspaceId: workspace, title: "Activity test", provider: .codex, model: "test")
        try context.threadRepo.upsert(thread)
        return thread
    }
    private func makeRun(_ context: AppContext, thread: AgentThread, status: AgentRunStatus, at time: TimeInterval) throws -> AgentRun {
        let date = Date(timeIntervalSince1970: time)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "test", status: status, startedAt: date, finishedAt: status == .running || status == .pending ? nil : date)
        try context.runRepo.upsert(run)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date)
        let statement = try context.db.prepare("UPDATE agent_runs SET started_at = ?, finished_at = ? WHERE id = ?;")
        try statement.bind(1, stamp)
        try statement.bind(2, run.finishedAt == nil ? nil : stamp)
        try statement.bind(3, run.id.description)
        _ = try statement.step()
        return run
    }
    private func insertResult(_ context: AppContext, runID: AgentRunID) throws {
        let statement = try context.db.prepare("INSERT OR IGNORE INTO agent_run_results(run_id) VALUES (?);")
        try statement.bind(1, runID.description)
        _ = try statement.step()
    }
    private func insertCheckpoint(_ context: AppContext, runID: AgentRunID, threadID: AgentThreadID, file: String, sequence: Int, turnID: String? = nil) throws {
        let turnID = turnID ?? UUID().uuidString
        let files = [AgentTurnCheckpointFile(path: file, kind: "modified", additions: 1, deletions: 0)]
        let filesJSON = String(decoding: try JSONEncoder().encode(files), as: UTF8.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let statement = try context.db.prepare("""
            INSERT INTO agent_turn_checkpoints(thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, completed_at, created_at)
            VALUES (?, ?, ?, ?, 'test-ref', 'ready', ?, ?, ?);
            """)
        try statement.bind(1, threadID.description)
        try statement.bind(2, runID.description)
        try statement.bind(3, turnID)
        try statement.bind(4, sequence)
        try statement.bind(5, filesJSON)
        try statement.bind(6, formatter.string(from: Date()))
        try statement.bind(7, formatter.string(from: Date()))
        _ = try statement.step()
    }
    private func pendingRequest(_ id: String) -> AssistantPendingRequest {
        AssistantPendingRequest(id: id, turnId: nil, kind: .commandExecution, title: "not exposed", createdAtMs: 101_000)
    }
    private func service(_ context: AppContext, activeRunID: AgentRunID? = nil) -> ActivityService {
        ActivityService(context: context, activeRunIDProvider: { _ in activeRunID })
    }
    private func decodePage(_ value: JSONValue) throws -> AgentActivityPage {
        let decoder = AgentActivityPage.makeJSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentActivityPage.self, from: JSONEncoder().encode(value))
    }
}

final class ActivityChangeEmitterTests: XCTestCase {
    private func item(_ id: String, thread: UUID?, workspace: UUID?, state: AgentActivityState = .running, occurredAt: TimeInterval = 100) -> AgentActivityItem {
        AgentActivityItem(id: id, kind: .agent, workspaceID: workspace, threadID: thread, state: state, title: "t", occurredAt: Date(timeIntervalSince1970: occurredAt))
    }

    func testDiffReportsOnlyRowsThatChangedOrVanishedPerWorkspace() {
        // WHY: iOS applies the delta to its per-workspace counts; an unchanged row must not
        // wake the phone, and a vanished row must still announce its workspace.
        let ws = UUID(), thread = UUID(), otherThread = UUID()
        let before = ActivityChangeEmitter.diff(previous: [:], items: [item("a", thread: thread, workspace: ws), item("b", thread: otherThread, workspace: ws)])
        let unchanged = ActivityChangeEmitter.diff(previous: before.rows, items: [item("a", thread: thread, workspace: ws), item("b", thread: otherThread, workspace: ws)])
        XCTAssertTrue(unchanged.changedThreads.isEmpty)

        let flipped = ActivityChangeEmitter.diff(previous: before.rows, items: [item("a", thread: thread, workspace: ws, state: .completed), item("b", thread: otherThread, workspace: ws)])
        XCTAssertEqual(flipped.changedThreads[ws.uuidString], [thread.uuidString])

        let removed = ActivityChangeEmitter.diff(previous: before.rows, items: [item("b", thread: otherThread, workspace: ws)])
        XCTAssertEqual(removed.changedThreads[ws.uuidString], [thread.uuidString], "a row that left Activity must still notify its thread")
    }

    func testRowsWithoutWorkspaceNeverPublish() {
        let diffed = ActivityChangeEmitter.diff(previous: [:], items: [item("n", thread: UUID(), workspace: nil)])
        XCTAssertTrue(diffed.changedThreads.isEmpty)
    }

    func testPublishDelayCapsEachWorkspaceAtTwoPerSecond() {
        // WHY: a streaming run flips counts many times a second; the phone must see at most
        // 2 events per workspace per second, and the first change after quiet goes out now.
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ActivityChangeEmitter.publishDelay(lastPublished: nil, now: now), 0)
        XCTAssertEqual(ActivityChangeEmitter.publishDelay(lastPublished: now.addingTimeInterval(-0.1), now: now), 0.4, accuracy: 0.001)
        XCTAssertEqual(ActivityChangeEmitter.publishDelay(lastPublished: now.addingTimeInterval(-5), now: now), 0)
    }

    func testPayloadMatchesWorkspaceCountsShape() throws {
        let counts = AgentActivityCounts(running: 2, queued: 1, needsYou: 3, finished: 4, newResults: 5)
        let payload = ActivityChangeEmitter.payload(workspaceID: "ws-1", counts: counts, changedThreadIDs: ["t2", "t1"])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AgentActivityCounts.self, from: JSONEncoder().encode(try XCTUnwrap(payload.objectValue?["counts"])))
        XCTAssertEqual(decoded, counts, "counts must decode with the same keys as workspace_counts entries")
        XCTAssertEqual(payload.objectValue?["workspace_id"]?.stringValue, "ws-1")
        XCTAssertEqual(payload.objectValue?["changed_thread_ids"]?.arrayValue?.compactMap(\.stringValue), ["t1", "t2"])
        XCTAssertFalse(data.isEmpty)
    }
}
