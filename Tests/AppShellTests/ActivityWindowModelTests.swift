import XCTest
@testable import AppShell
import SocketServer

@MainActor
final class ActivityWindowModelTests: XCTestCase {
    private func item(_ id: String, at date: String = "2026-10-12T11:59:00Z", viewed: String? = nil, kind: String = "agent", state: String = "completed", needsAction: Bool? = nil) -> ActivityWireItem {
        ActivityWireItem(
            id: id, kind: kind, run_id: "run", request_id: nil, notification_id: nil,
            workspace_id: "workspace", thread_id: nil, surface_id: nil, state: state,
            title: id, workspace_name: "Workspace", provider: "Codex", summary: "Summary",
            occurred_at: date, started_at: nil, finished_at: nil, viewed_at: viewed,
            attention_acknowledged_at: nil, needs_action: needsAction ?? (kind == "request"), blocking: false,
            final_message_id: nil, checkpoint_id: nil, changed_files: [], error: nil
        )
    }

    private func json<T: Encodable>(_ value: T) -> JSONValue {
        JSONValue.decode(from: try! JSONEncoder().encode(value))!
    }

    private func page(_ items: [ActivityWireItem], cursor: String? = nil, counts: ActivityWireCounts = .init(), generatedAt: String? = "2026-10-12T12:00:00Z") -> JSONValue {
        json(ActivityWirePage(items: items, next_cursor: cursor, counts: counts, generated_at: generatedAt))
    }

    private func updated(_ ids: [String]) -> JSONValue {
        .object(["updated_ids": .array(ids.map(JSONValue.string))])
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(2), condition: @escaping () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    func testCacheAndSelectionAreImmediateThenFreshResponseWins() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        let cached = ActivityWirePage(items: [item("cached")], counts: .init(), generated_at: nil)
        let fresh = page([item("fresh")], counts: ActivityWireCounts(running: 2, needs_you: 3, finished: 4))
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in fresh }, setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.loadCached(cached)
        model.selectedID = "cached"
        model.scrollID = "cached"
        XCTAssertEqual(model.page.items.first?.id, "cached")
        XCTAssertEqual(model.selectedID, "cached")
        XCTAssertEqual(model.scrollID, "cached")
        model.refreshAfterFrame()
        await waitUntil("fresh result") { model.page.items.first?.id == "fresh" }
        XCTAssertEqual(model.page.items.first?.id, "fresh")
        XCTAssertEqual(model.page.counts.finished, 4)
        XCTAssertEqual(model.tab, .needsYou, "first visit prefers action-needed work from host scope counts")
    }

    func testRestoredTabSurvivesHostCountsAndPeriodPersistsSinceQuery() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        var request: [String: JSONValue] = [:]
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in request = params; return self.page([], counts: .init(running: 8, needs_you: 3, finished: 9)) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.period = .week
        model.refreshAfterFrame()
        await waitUntil("period query") { request["since"] != nil }
        XCTAssertEqual(model.tab, .finished, "restored tab must not change when counts refresh")
        XCTAssertEqual(request["section"]?.stringValue, "finished")
        XCTAssertEqual(request["limit"]?.intValue, 50)
        XCTAssertNotNil(request["since"]?.stringValue)
        XCTAssertEqual(defaults.string(forKey: "activity.period"), "week")
    }

    func testRestoredTargetPagesUntilExactItemAndMissingTargetDoesNotMarkSeen() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        defaults.set("run:target", forKey: "activity.selection")
        defaults.set("run:target", forKey: "activity.scroll")
        var listCalls = 0
        var mutations = 0
        let first = page((0..<50).map { item("run-\($0)") }, cursor: "frozen-next")
        let second = page([item("run:target")])
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                listCalls += 1
                if params["cursor"] == nil { return first }
                XCTAssertEqual(params["cursor"]?.stringValue, "frozen-next")
                return second
            },
            setViewed: { _ in mutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("restored target on second page") { model.detail?.id == "run:target" }
        XCTAssertEqual(model.scrollID, "run:target")
        model.detailPresented(model.detail!)
        await model.waitForPendingWrites()
        XCTAssertEqual(mutations, 1, "only mounting the exact detail may mark the result seen")

        let missingDefaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        missingDefaults.set("finished", forKey: "activity.tab")
        missingDefaults.set("run:missing", forKey: "activity.selection")
        var missingMutations = 0
        let missing = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([self.item("other")]) },
            setViewed: { _ in missingMutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: missingDefaults)
        missing.refreshAfterFrame()
        await waitUntil("missing restored target dropped") { missing.selectedID == nil && !missing.loading }
        XCTAssertNil(missing.detail)
        XCTAssertNil(missing.error, "a restored selection is convenience state, not a target the user asked for")
        XCTAssertNil(missingDefaults.string(forKey: "activity.selection"))
        XCTAssertEqual(missingMutations, 0, "missing target must never mark another result seen")
    }

    func testRestoredSelectionThatLeftRunningIsDroppedSilentlyAndNeverReRaisedOnLiveRefresh() async {
        // WHY: the saved selection is usually a run clicked last session that has since finished.
        // Treating it as a requested target showed "Update failed: Requested activity result was
        // not found." over an unrelated Running row, and re-raised it on every agent.run.* refresh.
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("running", forKey: "activity.tab")
        defaults.set("run:finished-earlier", forKey: "activity.selection")
        defaults.set("run:finished-earlier", forKey: "activity.scroll")
        var listCalls = 0
        var mutations = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                listCalls += 1
                return params["cursor"] == nil
                    ? self.page([self.item("run:oi", state: "running")], cursor: "more")
                    : self.page([self.item("run:other", state: "running")])
            },
            setViewed: { _ in mutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)

        model.refreshAfterFrame()
        await waitUntil("first refresh") { listCalls >= 1 && !model.loading }
        XCTAssertNil(model.error)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.detail)
        XCTAssertNil(defaults.string(forKey: "activity.selection"), "the dropped selection must not come back next launch")
        XCTAssertEqual(model.page.items.first?.id, "run:oi", "the running bot row is still shown")
        XCTAssertEqual(mutations, 0)
        let callsAfterFirst = listCalls

        for refresh in 1...2 {
            model.refreshAfterFrame()
            await waitUntil("live refresh \(refresh)") { listCalls == callsAfterFirst + refresh && !model.loading }
            XCTAssertNil(model.error, "an invalidation refresh must not raise a missing-target error")
        }
        XCTAssertEqual(listCalls, callsAfterFirst + 2, "a dropped target must not be paged for again")
    }

    func testExplicitRouteMissIsReportedOnceAndStaysDismissedAcrossLiveRefreshes() async {
        // WHY: a notification that names a row the host no longer lists must say so, once.
        // Left armed, every agent.run.* refresh paged for it again and re-raised the banner,
        // so Dismiss and Retry could never make it go away.
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var listCalls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                listCalls += 1
                return params["cursor"] == nil ? self.page([self.item("other")], cursor: "more") : self.page([])
            },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true, activityItemId: "run:gone"))
        await waitUntil("routed miss") { model.error != nil && !model.loading }
        XCTAssertEqual(model.error, "Requested activity result was not found.")
        let callsAfterMiss = listCalls

        model.refreshAfterFrame()
        await waitUntil("invalidation refresh") { listCalls == callsAfterMiss + 1 && !model.loading }
        XCTAssertEqual(model.error, "Requested activity result was not found.",
                       "an invalidation 100 ms later must not wipe the honest error before it can be read")
        model.dismissError()
        model.refreshAfterFrame()
        await waitUntil("refresh after dismiss") { listCalls == callsAfterMiss + 2 && !model.loading }
        XCTAssertNil(model.error, "a dismissed miss must not come back")
        XCTAssertEqual(listCalls, callsAfterMiss + 2, "the missed target is searched for once, not on every refresh")
    }

    func testAcknowledgedNeedsYouSelectionDisappearingOnRefreshDoesNotReportMissingExternalTarget() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        var listCalls = 0
        var acknowledged = false
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                listCalls += 1
                return self.page(acknowledged ? [] : [self.item("failed", state: "failed", needsAction: true)])
            },
            setViewed: { params in self.updated(params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []) },
            acknowledge: { _ in acknowledged = true; return .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("Needs you result loaded") { model.page.items.count == 1 && !model.loading }
        model.openDetail(model.page.items[0])

        model.acknowledge(model.page.items[0])

        await waitUntil("acknowledgment refresh completed") { listCalls == 2 && !model.loading }
        XCTAssertTrue(acknowledged)
        XCTAssertNil(model.error)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.page.items.isEmpty)

        let routedDefaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        let routed = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([]) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: routedDefaults)
        routed.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true, activityItemId: "external-target"))
        await waitUntil("missing external route error") { routed.error != nil && !routed.loading }
        XCTAssertEqual(routed.error, "Requested activity result was not found.")
        XCTAssertEqual(routed.selectedID, "external-target")

        let resolvedDefaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var didAcknowledge = false
        var resolvedListCalls = 0
        let routedFailure = self.item("routed-failure", state: "failed", needsAction: true)
        let resolved = ActivityViewModel(service: ActivityClient(
            list: { _ in resolvedListCalls += 1; return self.page(didAcknowledge ? [] : [routedFailure]) },
            setViewed: { params in self.updated(params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []) },
            acknowledge: { _ in didAcknowledge = true; return .object([:]) }
        ), defaults: resolvedDefaults)
        resolved.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true, activityItemId: "routed-failure"))
        await waitUntil("external target resolved") { resolved.detail?.id == "routed-failure" && !resolved.loading }
        resolved.acknowledge(routedFailure)
        await waitUntil("resolved external target acknowledgment refresh") { didAcknowledge && resolvedListCalls == 2 && !resolved.loading }
        XCTAssertNil(resolved.error)
        XCTAssertNil(resolved.selectedID)
    }

    func testExplicitActivityRouteReplacesMountedFiltersWithoutMarkingResultsSeen() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var request: [String: JSONValue]?
        var mutations = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in request = params; return self.page([]) },
            setViewed: { _ in mutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.search = "old search"
        model.outcome = "failed"
        model.period = .week
        model.selectedID = "old result"
        model.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true))
        XCTAssertEqual(model.tab, .finished)
        XCTAssertEqual(model.search, "")
        XCTAssertEqual(model.outcome, "")
        XCTAssertEqual(model.period, .all)
        XCTAssertNil(model.selectedID)
        await waitUntil("explicit Activity route freshness") { request != nil }
        XCTAssertEqual(request?["section"]?.stringValue, "finished")
        XCTAssertNil(request?["since"])
        XCTAssertEqual(mutations, 0, "opening grouped results must not mark any occurrence seen")
    }

    func testRecordedDurationUsesRunTimestampsAndRejectsNegativeIntervals() {
        var run = item("duration")
        run.started_at = "2026-10-12T12:00:00.000Z"
        run.finished_at = "2026-10-12T12:04:12.000Z"
        XCTAssertEqual(run.durationLabel, "4m 12s")
        run.finished_at = "2026-10-12T16:05:00Z"
        XCTAssertEqual(run.durationLabel, "4h 5m", "an hours-long run must not read as hundreds of minutes")
        run.finished_at = "2026-10-12T11:59:00Z"
        XCTAssertNil(run.durationLabel, "invalid timestamp order must never fabricate elapsed time")
    }

    func testFailedResultCanBeViewedWithoutAcknowledgmentButLiveRunCannot() {
        let failed = item("failed", state: "failed", needsAction: true)
        let running = item("running", state: "running")
        XCTAssertTrue(failed.isMarkable)
        XCTAssertTrue(failed.needs_action, "viewing failure must not acknowledge it")
        XCTAssertFalse(running.isMarkable, "running result must not be marked viewed")
        XCTAssertFalse(item("request", kind: "request", state: "failed").isMarkable)
    }

    func testDetailViewedMutationExcludesRequestAndMarkUnreadClearsTimestampWithoutUndoBanner() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var mutations: [[String: JSONValue]] = []
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([]) },
            setViewed: { params in
                mutations.append(params)
                return self.updated(params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        let result = item("run:one")
        model.openDetail(result)
        XCTAssertTrue(mutations.isEmpty, "opening a result must not mark it seen before detail mounts")
        model.detailPresented(result)
        await model.waitForPendingWrites()
        XCTAssertEqual(mutations.first?["item_ids"]?.arrayValue?.compactMap(\.stringValue), ["run:one"])
        XCTAssertEqual(mutations.first?["viewed"]?.boolValue, true)
        XCTAssertNotNil(model.detail?.viewed_at, "the host-confirmed read state must show before the refresh returns")
        XCTAssertNil(model.batchStatus, "reading one result by opening it must not raise an Undo banner")
        XCTAssertNil(model.undoCount)

        var request = result
        request.kind = "request"
        model.openDetail(request)
        model.detailPresented(request)
        await model.waitForPendingWrites()
        XCTAssertEqual(mutations.count, 1, "a request has no read state to mutate")

        var read = result
        read.viewed_at = "2026-10-12T12:00:00Z"
        model.markUnread(read)
        await model.waitForPendingWrites()
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations.last?["viewed"]?.boolValue, false)
        XCTAssertEqual(mutations.last?["item_ids"]?.arrayValue?.compactMap(\.stringValue), ["run:one"])
    }

    func testBatchCapturesAllFilteredPagesButExcludesArrivalAfterSnapshotAndUndoRestoresNil() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        defaults.set("week", forKey: "activity.period")
        defaults.set("needle", forKey: "activity.search")
        defaults.set("workspace", forKey: "activity.workspace")
        var listCalls = 0
        // Sampled at the mutation: the refresh that follows the batch lists again and must not race this count.
        var listCallsBeforeMutation = 0
        var mutationCalls: [[String: JSONValue]] = []
        let first = page((0..<50).map { item("run-\($0)", at: "2026-10-12T11:59:00Z") }, cursor: "next")
        let second = page([
            item("run-50", at: "2026-10-12T11:58:00Z"),
            item("request-callback", at: "2026-10-12T11:58:00Z", kind: "request"),
            item("arrival-after-cutoff", at: "2026-10-12T12:01:00Z")
        ])
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                listCalls += 1
                XCTAssertEqual(params["section"]?.stringValue, "finished")
                XCTAssertEqual(params["search"]?.stringValue, "needle")
                XCTAssertEqual(params["workspace_id"]?.stringValue, "workspace")
                // The first two calls are the batch; the refresh that follows asks for an ordinary page.
                if listCalls <= 2 {
                    XCTAssertEqual(params["limit"]?.intValue, 500, "each page is a full host pass, so a bulk read must not walk the filter 50 rows at a time")
                }
                XCTAssertNotNil(params["since"]?.stringValue)
                return listCalls == 1 ? first : second
            },
            setViewed: { params in
                if mutationCalls.isEmpty { listCallsBeforeMutation = listCalls }
                mutationCalls.append(params)
                let ids = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                XCTAssertLessThanOrEqual(ids.count, 200)
                return self.updated(ids)
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.period = .week
        model.markCurrentResultsSeen()
        await waitUntil("batch completion") { !model.batchRunning }
        XCTAssertEqual(listCallsBeforeMutation, 2, "batch must page beyond the visible 50 rows")
        XCTAssertEqual(mutationCalls.count, 1)
        let changed = mutationCalls[0]["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(changed.count, 51)
        XCTAssertFalse(changed.contains("arrival-after-cutoff"), "new arrivals after captured generated_at stay outside batch")
        XCTAssertFalse(changed.contains("request-callback"), "request callbacks are not bulk-marked as viewed")
        XCTAssertEqual(model.undoCount, 51)

        await model.undoLastAction()
        XCTAssertEqual(mutationCalls.count, 2)
        let undo = mutationCalls[1]
        XCTAssertEqual(undo["viewed"]?.boolValue, false)
        XCTAssertEqual(undo["restore_viewed_at"]?.objectValue?.count, 51)
        XCTAssertTrue(undo["restore_viewed_at"]?.objectValue?.values.allSatisfy { $0 == .null } == true)
    }

    func testBatchUsesClickTimeCutoffEvenWhenResponseSnapshotIsNewer() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let afterClick = formatter.string(from: Date().addingTimeInterval(30))
        let responseTime = formatter.string(from: Date().addingTimeInterval(60))
        var changedIDs: [String] = []
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([self.item("arrived-after-click", at: afterClick)], generatedAt: responseTime) },
            setViewed: { params in
                changedIDs = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return self.updated(changedIDs)
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)

        model.markCurrentResultsSeen()
        await waitUntil("batch completion") { !model.batchRunning }
        XCTAssertTrue(changedIDs.isEmpty, "response-time arrivals must stay outside click-time batch")
        XCTAssertEqual(model.batchStatus, "No unread results match this filter.")
    }

    func testBatchPartialResponseReportsExactCountAndUndoOnlyUpdatedIDs() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        var setCalls = 0
        var mutations: [[String: JSONValue]] = []
        let first = page((0..<50).map { item("run-\($0)") }, cursor: "next")
        let second = page([item("run-50", at: "2026-10-12T11:58:00Z")])
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in params["cursor"] == nil ? first : second },
            setViewed: { params in
                mutations.append(params)
                setCalls += 1
                let ids = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return self.updated(setCalls == 1 ? Array(ids.prefix(20)) : ids)
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.markCurrentResultsSeen()
        await waitUntil("batch completion") { !model.batchRunning }
        XCTAssertEqual(model.undoCount, 20)
        XCTAssertTrue(model.error?.contains("20") == true, "partial host result must report successful count")
        XCTAssertEqual(mutations.count, 1, "stop after host reports partial update")
        await model.undoLastAction()
        XCTAssertEqual(mutations.count, 2)
        let ids = mutations[1]["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(ids.count, 20)
        XCTAssertTrue(mutations[1]["restore_viewed_at"]?.objectValue?.values.allSatisfy { $0 == .null } == true)
    }

    func testActivityInvalidationFloodCoalescesRefreshAndPreservesSelection() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in calls += 1; return self.page([self.item("latest")]) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("automatic initial tab load") { calls > 0 && !model.loading }
        let settledInitialCalls = calls
        model.selectedID = "latest"
        for _ in 0..<30 {
            EventBus.shared.publish(kind: .agentRunFinished, payload: .object(["id": .string(UUID().uuidString)]))
        }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls - settledInitialCalls, 1, "invalidation flood must add one latest-wins refresh after automatic initial tab selection")
        XCTAssertEqual(model.selectedID, "latest")
    }

    func testRequestEventsInvalidateAndQueuedItemsStaySeparateFromRunning() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let queued = item("queued", state: "queued")
        let running = item("running", state: "running")
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in calls += 1; return self.page([queued, running], counts: ActivityWireCounts(running: 1, queued: 1)) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("initial activity result") { calls > 0 && !model.loading }
        XCTAssertEqual(model.runningItems.map(\.id), ["running"])
        XCTAssertEqual(model.queuedItems.map(\.id), ["queued"])
        EventBus.shared.publish(kind: .agentRequestOpened, payload: .object([:]))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    func testFilterChangeClearsPriorScopeWhenMatchingCacheMissingAndRefreshFails() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                calls += 1
                if calls == 1 { return self.page([self.item("old-scope")], counts: ActivityWireCounts(running: 1)) }
                throw NSError(domain: "offline", code: 2)
            },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("initial activity result") { calls > 0 && !model.loading }
        XCTAssertEqual(model.page.items.first?.id, "old-scope")
        model.workspaceID = "other-workspace"
        XCTAssertTrue(model.page.items.isEmpty)
        await waitUntil("refresh error") { model.error != nil }
        XCTAssertTrue(model.page.items.isEmpty, "failed refresh must not restore rows from prior scope")
        XCTAssertFalse(model.hasSuccessfulSnapshot)
    }

    func testRapidFilterChangeAndOfflineFailureStayExplicit() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                calls += 1
                return self.page([self.item(calls == 1 ? "stale" : "latest")], counts: ActivityWireCounts(running: 1))
            },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("first activity result") { calls > 0 && !model.loading }
        XCTAssertEqual(model.page.items.first?.id, "stale")
        model.search = "new target"
        model.refreshAfterFrame()
        await waitUntil("latest activity result") { model.page.items.first?.id == "latest" && !model.loading }
        XCTAssertEqual(model.page.items.first?.id, "latest")
        XCTAssertNil(model.error)

        let failing = ActivityViewModel(service: ActivityClient(
            list: { _ in throw NSError(domain: "offline", code: 2) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        failing.refreshAfterFrame()
        await waitUntil("offline error") { failing.error != nil }
        XCTAssertNotNil(failing.error, "offline refresh must not look like successful empty results")
    }

    private func echoViewed(_ params: [String: JSONValue]) -> JSONValue {
        updated(params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    func testEveryNeedsYouItemCanBeClearedSoClearAllLeavesNothingBehind() {
        // WHY: the owner (2026-10-14) wants Clear all to empty Needs you. An expired
        // approval that could not be cleared stayed there forever.
        XCTAssertTrue(item("run:failed", state: "failed", needsAction: true).isClearable)
        XCTAssertTrue(item("run:interrupted", state: "interrupted", needsAction: true).isClearable)
        XCTAssertTrue(item("bot-attention:one", kind: "request", state: "waiting_answer").isClearable,
                      "a bot request stays in its conversation, so leaving Needs you loses nothing")
        XCTAssertTrue(item("request:thread:approval", kind: "request", state: "waiting_approval").isClearable,
                      "a provider approval leaves the inbox; its card still waits in the thread")
        XCTAssertTrue(item("request:thread:expired", kind: "request", state: "expired").isClearable,
                      "an expired request has nothing left to answer")
        XCTAssertTrue(item("notification:conflict", kind: "notification", state: "needs_you", needsAction: true).isClearable,
                      "a file conflict leaves the inbox; the conflict itself is untouched")
        XCTAssertTrue(item("run:orphan", state: "needs_you", needsAction: true).isClearable)
        XCTAssertFalse(item("run:acknowledged", state: "failed", needsAction: false).isClearable,
                       "an already cleared failure has nothing left to clear")
        XCTAssertFalse(item("bot-attention:one", kind: "request", state: "waiting_answer").isUnread,
                       "a request has no read state, so it must never show as a new result")
        XCTAssertEqual(item("run:orphan", state: "needs_you").statusLabel, "Run interrupted",
                       "the label must describe why this run can be resumed")
    }

    func testClearingSelectedNeedsYouItemRemovesItAdvancesSelectionAndUndoRestoresExactState() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        let first = item("run:first", state: "failed", needsAction: true)
        let second = item("run:second", viewed: "2026-10-12T10:00:00Z", state: "failed", needsAction: true)
        var cleared = Set<String>()
        var acknowledgeCalls: [[String: JSONValue]] = []
        var viewedCalls: [[String: JSONValue]] = []
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                let open = [first, second].filter { !cleared.contains($0.id) }
                return self.page(open, counts: ActivityWireCounts(needs_you: open.count))
            },
            setViewed: { params in viewedCalls.append(params); return self.echoViewed(params) },
            acknowledge: { params in
                acknowledgeCalls.append(params)
                if let id = params["item_id"]?.stringValue { cleared.insert(id); return .object(["acknowledged": .bool(true), "item_id": .string(id)]) }
                let ids = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if params["acknowledged"]?.boolValue == false { cleared.subtract(ids) }
                return self.updated(ids)
            }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("Needs you loaded") { model.page.items.count == 2 && !model.loading }
        model.openDetail(first)

        model.acknowledge(first)
        await model.waitForPendingWrites()

        XCTAssertEqual(model.page.items.map(\.id), ["run:second"], "the cleared row must leave on the click turn, before the refresh")
        XCTAssertEqual(model.page.counts.needs_you, 1)
        XCTAssertEqual(model.selectedID, "run:second", "triage continues on the neighbor instead of dropping the selection")
        XCTAssertEqual(acknowledgeCalls.first?["item_id"]?.stringValue, "run:first")
        XCTAssertEqual(viewedCalls.first?["item_ids"]?.arrayValue?.compactMap(\.stringValue), ["run:first"],
                       "a cleared failure must not linger as a new result in Finished")
        XCTAssertEqual(model.undoCount, 1)
        await waitUntil("refresh after clear") { !model.loading }

        await model.undoLastAction()

        XCTAssertEqual(acknowledgeCalls.last?["acknowledged"]?.boolValue, false)
        XCTAssertEqual(acknowledgeCalls.last?["item_ids"]?.arrayValue?.compactMap(\.stringValue), ["run:first"])
        XCTAssertEqual(viewedCalls.last?["restore_viewed_at"]?.objectValue?["run:first"], .null,
                       "undo must return the result to unread, exactly as it was")
        XCTAssertNil(model.undoCount)
        await waitUntil("undo refresh") { model.page.items.count == 2 && !model.loading }
        XCTAssertNil(model.error)
    }

    func testClearAllCoversEveryPageAndEveryKindOfTheFilterButNeverTouchesLaterArrivals() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        defaults.set("workspace", forKey: "activity.workspace")
        let firstPage = (0..<50).map { item("run:\($0)", state: "failed", needsAction: true) }
        let secondPage = [
            item("run:50", viewed: "2026-10-12T09:00:00Z", state: "interrupted", needsAction: true),
            item("bot-attention:question", kind: "request", state: "waiting_answer"),
            item("request:thread:approval", kind: "request", state: "waiting_approval"),
            item("notification:conflict", kind: "notification", state: "needs_you", needsAction: true),
            item("run:late", at: "2026-10-12T12:01:00Z", state: "failed", needsAction: true),
            item("run:raced", state: "failed", needsAction: true)
        ]
        var acknowledged: [String] = []
        var viewed: [String] = []
        var batchDone = false
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                XCTAssertEqual(params["section"]?.stringValue, "needs_you")
                XCTAssertEqual(params["workspace_id"]?.stringValue, "workspace")
                if batchDone { return self.page([]) }
                return params["cursor"] == nil ? self.page(firstPage, cursor: "next") : self.page(secondPage)
            },
            setViewed: { params in
                viewed += params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return self.echoViewed(params)
            },
            acknowledge: { params in
                let ids = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                XCTAssertLessThanOrEqual(ids.count, 200)
                XCTAssertEqual(params["acknowledged"]?.boolValue, true)
                acknowledged += ids
                batchDone = true
                return self.updated(ids.filter { $0 != "run:raced" })
            }
        ), defaults: defaults)

        model.clearCurrentNeedsYou()
        XCTAssertTrue(model.batchRunning, "the click must be acknowledged before any host work")
        await waitUntil("clear all completion") { !model.batchRunning }

        XCTAssertEqual(acknowledged.count, 55)
        XCTAssertTrue(acknowledged.contains("bot-attention:question"))
        XCTAssertTrue(acknowledged.contains("request:thread:approval"), "Clear all leaves nothing in Needs you")
        XCTAssertTrue(acknowledged.contains("notification:conflict"), "Clear all leaves nothing in Needs you")
        XCTAssertFalse(acknowledged.contains("run:late"), "arrivals after the click stay in Needs you")
        XCTAssertFalse(viewed.contains("run:50"), "an already read result needs no read mutation")
        XCTAssertFalse(viewed.contains("bot-attention:question"), "a request has no read state")
        XCTAssertFalse(viewed.contains("run:raced"), "an item the host did not clear must keep its unread state")
        XCTAssertEqual(viewed.count, 50)
        XCTAssertEqual(model.undoCount, 54, "Undo covers exactly what the host confirmed")
        XCTAssertEqual(model.batchStatus, "Dismissed 54 from Needs you.")
        XCTAssertNil(model.error, "an item another client already resolved is not a failure")
    }

    func testClearFailureIsReportedAndSurvivesTheNextRefreshWhileNothingIsRemoved() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        let failed = item("run:failed", state: "failed", needsAction: true)
        var listCalls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in listCalls += 1; return self.page([failed], counts: ActivityWireCounts(needs_you: 1)) },
            setViewed: { params in self.echoViewed(params) },
            acknowledge: { _ in throw NSError(domain: "host", code: 9, userInfo: [NSLocalizedDescriptionKey: "host rejected"]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("Needs you loaded") { model.page.items.count == 1 && !model.loading }

        model.acknowledge(failed)
        await model.waitForPendingWrites()

        XCTAssertEqual(model.error, "host rejected")
        XCTAssertEqual(model.page.items.map(\.id), ["run:failed"], "a rejected clear must not look cleared")
        XCTAssertEqual(model.page.counts.needs_you, 1)
        XCTAssertNil(model.undoCount)
        let callsBefore = listCalls
        model.refreshAfterFrame()
        await waitUntil("follow-up refresh") { listCalls > callsBefore && !model.loading }
        XCTAssertEqual(model.error, "host rejected", "a successful refresh must not erase an action failure the user has not seen")
    }

    func testRefreshAsksForThePagedDepthInOneRequestSoALiveEventDoesNotThrowTheReaderBackToPageOne() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        let all = (0..<60).map { item("run:\($0)") }
        var requests: [[String: JSONValue]] = []
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                requests.append(params)
                if params["cursor"] != nil { return self.page(Array(all[50...])) }
                return (params["limit"]?.intValue ?? 50) >= 60 ? self.page(all) : self.page(Array(all[..<50]), cursor: "page-2")
            },
            setViewed: { params in self.echoViewed(params) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("first page") { model.page.items.count == 50 && !model.loading }
        XCTAssertEqual(requests.map { $0["limit"]?.intValue }, [50], "a first load asks for one ordinary page")
        model.loadMore()
        await waitUntil("second page") { model.page.items.count == 60 && !model.loading }
        requests.removeAll()

        model.refreshAfterFrame()
        await waitUntil("refresh settled") { !requests.isEmpty && !model.loading }

        XCTAssertEqual(requests.count, 1, "the host recomputes everything per request, so depth must not cost extra passes")
        XCTAssertEqual(requests.first?["limit"]?.intValue, 60)
        XCTAssertNil(requests.first?["cursor"])
        XCTAssertEqual(model.page.items.count, 60, "rows the reader paged to must survive a refresh")
        XCTAssertFalse(model.cursorAvailable)
    }

    func testMarkAllAsReadIsOnlyOfferedWhileTheFilterHoldsSomethingUnread() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        var response = page([item("run:read", viewed: "2026-10-12T10:00:00Z")], counts: ActivityWireCounts(finished: 1, new_results: 0))
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in response }, setViewed: { params in self.echoViewed(params) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("read results") { model.page.items.count == 1 && !model.loading }
        XCTAssertFalse(model.hasUnreadResults, "with nothing unread the action must read as unavailable, not run and report nothing")

        response = page([item("run:read", viewed: "2026-10-12T10:00:00Z")], counts: ActivityWireCounts(finished: 80, new_results: 3))
        model.refreshAfterFrame()
        await waitUntil("host count") { model.page.counts.new_results == 3 && !model.loading }
        XCTAssertTrue(model.hasUnreadResults, "unread results beyond the loaded rows still count")
    }

    func testCompactAgeNeverShowsNegativeTimeAndSwitchesUnitsAtReadableBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ seconds: TimeInterval) -> String { ActivityTimeLabel.compact(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(age(-120), "now", "a host clock ahead of this Mac must not render a negative age")
        XCTAssertEqual(age(59), "now")
        XCTAssertEqual(age(60), "1m")
        XCTAssertEqual(age(3_599), "59m")
        XCTAssertEqual(age(3_600), "1h")
        XCTAssertEqual(age(86_399), "23h")
        XCTAssertEqual(age(86_400), "1d")
        XCTAssertEqual(age(6 * 86_400 + 86_399), "6d")
        let older = age(40 * 86_400)
        XCTAssertFalse(older.hasSuffix("d"), "beyond a week the row shows a date, not a growing day count")
        XCTAssertFalse(older.isEmpty)
    }

    func testListSummaryHidesHostPlaceholderAndFallsBackToTheFailureReason() {
        var run = item("run:one", state: "failed", needsAction: true)
        run.summary = ActivityWireItem.missingSummary
        XCTAssertNil(run.listSummary, "a placeholder repeated on every row is noise, not information")
        run.error = "Provider exited\nwith status 1"
        XCTAssertEqual(run.listSummary, "Provider exited with status 1", "a multi-line reason must not stretch the row")
        run.summary = "Added validation"
        XCTAssertEqual(run.listSummary, "Added validation")
        run.title = "  \n  "
        XCTAssertEqual(run.displayTitle, "Untitled", "a blank title must still give the row a readable name")
    }

    @MainActor
    private func inWorkspace(_ item: ActivityWireItem, _ id: String?, _ name: String?) -> ActivityWireItem {
        var copy = item
        copy.workspace_id = id
        copy.workspace_name = name
        return copy
    }

    @MainActor
    func test_sectionsGroupByWorkspaceInFirstAppearanceOrderAndAnswersLeadNeedsYou() async throws {
        // WHY: the owner scans Activity per project. Sections follow the newest-first list, so the
        // most recent workspace is on top; a workspace is keyed by id because names can collide.
        let defaults = UserDefaults(suiteName: "activity-sections-\(UUID())")!
        let fixture = [
            inWorkspace(item("elephant-task", state: "completed"), "ws-elephant", "Elephant"),
            inWorkspace(item("star-deploy", state: "completed"), "ws-star", "Star"),
            inWorkspace(item("loose", state: "completed"), nil, nil),
            inWorkspace(item("elephant-failed", state: "failed", needsAction: true), "ws-elephant", "Elephant"),
            inWorkspace(item("star-approval", kind: "request", state: "waiting_approval"), "ws-star", "Star-renamed"),
        ]
        let response = page(fixture)
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in response },
            setViewed: { _ in .object([:]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("loaded") { model.page.items.count == 5 && !model.loading }

        XCTAssertEqual(model.workspaceSections(model.page.items).map(\.title), ["Elephant", "Star", "No workspace"])
        XCTAssertEqual(model.workspaceSections(model.page.items).map { $0.items.map(\.id) },
                       [["elephant-task", "elephant-failed"], ["star-deploy", "star-approval"], ["loose"]])

        model.tab = .needsYou
        await waitUntil("needs you loaded") { model.page.items.count == 5 && !model.loading }
        XCTAssertEqual(model.listSections.first { $0.title == "Star" }?.items.map(\.id), ["star-approval", "star-deploy"],
                       "a reply the user owes comes before other rows of the same workspace")
        XCTAssertEqual(model.listSections.first { $0.title == "Elephant" }?.items.map(\.id), ["elephant-task", "elephant-failed"],
                       "without a waiting reply the newest-first order stays")
    }

    func testMarkReadShowsBeforeWriteAndRevertsWithErrorOnFailure() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        var gate: CheckedContinuation<Void, Never>?
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([self.item("run:read")]) },
            setViewed: { _ in
                await withCheckedContinuation { gate = $0 }
                throw NSError(domain: "host", code: 7, userInfo: [NSLocalizedDescriptionKey: "write failed"])
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("finished row loaded") { model.page.items.count == 1 && !model.loading }

        model.markRead(model.page.items[0])
        XCTAssertNotNil(model.page.items[0].viewed_at, "row must show read before the host write completes")
        await waitUntil("write suspended") { gate != nil }
        XCTAssertNotNil(model.page.items[0].viewed_at, "row stays read while the write is in flight")

        gate?.resume()
        await waitUntil("write failure surfaced") { model.error != nil }
        XCTAssertEqual(model.error, "write failed")
        XCTAssertNil(model.page.items[0].viewed_at, "a failed write must revert the row to unread")
    }

    func testAcknowledgeShowsBeforeWriteAndRestoresRowWithErrorOnFailure() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        let failed = item("run:failed", state: "failed", needsAction: true)
        var gate: CheckedContinuation<Void, Never>?
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([failed], counts: ActivityWireCounts(needs_you: 1)) },
            setViewed: { _ in .object([:]) },
            acknowledge: { _ in
                await withCheckedContinuation { gate = $0 }
                throw NSError(domain: "host", code: 9, userInfo: [NSLocalizedDescriptionKey: "host rejected"])
            }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("Needs you loaded") { model.page.items.count == 1 && !model.loading }

        model.acknowledge(failed)
        XCTAssertTrue(model.page.items.isEmpty, "the cleared row must leave on the click turn, before the write completes")
        XCTAssertEqual(model.undoCount, 1)
        await waitUntil("acknowledge write suspended") { gate != nil }

        gate?.resume()
        await waitUntil("acknowledge failure surfaced") { model.error != nil }
        XCTAssertEqual(model.error, "host rejected")
        XCTAssertEqual(model.page.items.map(\.id), ["run:failed"], "a rejected clear must restore the row")
        XCTAssertEqual(model.page.counts.needs_you, 1)
        XCTAssertNil(model.undoCount)
    }
}
