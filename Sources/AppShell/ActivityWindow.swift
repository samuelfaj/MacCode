import AppKit
import CoreModel
import Persistence
import DesignSystemKit
import SocketServer
import Surfaces
import SwiftUI

struct ActivityWireItem: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var run_id: String?
    var request_id: String?
    var notification_id: String?
    var workspace_id: String?
    var thread_id: String?
    var surface_id: String?
    var state: String
    var title: String
    var workspace_name: String?
    var provider: String?
    var summary: String?
    var occurred_at: String
    var started_at: String?
    var finished_at: String?
    var viewed_at: String?
    var attention_acknowledged_at: String?
    var needs_action: Bool
    var blocking: Bool
    var final_message_id: String?
    var checkpoint_id: String?
    var checkpoint_turn_count: Int? = nil
    var changed_files: [String] = []
    var error: String?
    var bot_id: String?
    var conversation_id: String?
    var origin_label: String?

    var durationLabel: String? {
        guard let start = started_at.flatMap(ActivityViewModel.parseDate),
              let finish = finished_at.flatMap(ActivityViewModel.parseDate) else { return nil }
        let interval = finish.timeIntervalSince(start)
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return nil }
        let seconds = Int(interval)
        return seconds >= 3_600 ? "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }
    var isNew: Bool { viewed_at == nil }
    var isMarkable: Bool { kind != "request" && ["completed", "failed", "interrupted", "stopped"].contains(state) }
    /// Requests have no read state, so only markable results can be unread.
    var isUnread: Bool { isMarkable && isNew }
    /// Clearing removes the item from Needs you only: a failure stays in Finished, and a
    /// request or conflict stays where it lives (its thread, bot conversation or file).
    /// Every Needs you item can be cleared, so Clear all leaves nothing behind.
    var isClearable: Bool { needs_action }
    var occurredDate: Date? { ActivityViewModel.parseDate(occurred_at) }
    var displayTitle: String {
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? "Untitled" : collapsed
    }
    /// Host placeholder for a terminal run without a summary; honest in the detail, noise in a list.
    static let missingSummary = "No summary available for this run"
    var listSummary: String? {
        let line = summary == Self.missingSummary ? error : summary ?? error
        let collapsed = line?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return collapsed.isEmpty ? nil : collapsed
    }
    var statusLabel: String {
        switch state {
        case "completed": "Completed"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        case "stopped": "Stopped by you"
        case "waiting_approval": "Waiting for approval"
        case "waiting_answer": "Waiting for your answer"
        case "queued": "Queued"
        case "running": "Running"
        case "expired": "Request expired"
        case "needs_you": kind == "agent" ? "Run interrupted" : "Review required"
        default: state.capitalized
        }
    }

    var attentionInstruction: String? {
        guard needs_action else { return nil }
        if kind == "request", let summary { return summary }
        switch state {
        case "waiting_approval":
            return "Approve or decline the request. This alert clears after your decision."
        case "waiting_answer":
            return "Send your response in this conversation. This alert clears when you reply."
        case "failed", "interrupted":
            if id.hasPrefix("scheduled-occurrence:") {
                return "Review this task in Schedule Tasks and run it again, or dismiss this alert."
            }
            if thread_id != nil {
                return "Send a new message to retry, or dismiss this alert. Starting a new run clears the previous failure."
            }
            return "Review the error at its source and retry, or dismiss this alert."
        case "needs_you":
            return kind == "agent"
                ? "This run has no active process. Send a new message to resume, or dismiss this alert."
                : "Resolve the issue at its source, or dismiss this alert. Opening it alone does not resolve it."
        default: return nil
        }
    }
}

enum ActivityTimeLabel {
    /// Compact age for list rows: "now", "12m", "3h", "2d", then a short date.
    /// A timestamp ahead of the clock reads as "now" instead of a negative age.
    static func compact(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).year())
    }

    static func full(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

struct ActivityWireCounts: Codable, Equatable, Sendable {
    var running: Int = 0
    var queued: Int = 0
    var needs_you: Int = 0
    var finished: Int = 0
    var new_results: Int = 0
}

struct ActivityWirePage: Codable, Equatable, Sendable {
    var items: [ActivityWireItem] = []
    var next_cursor: String?
    var counts: ActivityWireCounts = .init()
    var generated_at: String?
}

@MainActor
struct ActivityClient {
    var list: ([String: JSONValue]) async throws -> JSONValue
    var setViewed: @MainActor ([String: JSONValue]) throws -> JSONValue
    var acknowledge: @MainActor ([String: JSONValue]) throws -> JSONValue

    init(router: AppCommandRouter) {
        list = { try await router.activityListOffMain(params: $0) }
        setViewed = { try router.activitySetViewed(params: $0) }
        acknowledge = { try router.activityAcknowledge(params: $0) }
    }

    init(
        list: @escaping ([String: JSONValue]) async throws -> JSONValue,
        setViewed: @escaping @MainActor ([String: JSONValue]) throws -> JSONValue,
        acknowledge: @escaping @MainActor ([String: JSONValue]) throws -> JSONValue
    ) {
        self.list = list
        self.setViewed = setViewed
        self.acknowledge = acknowledge
    }
}

private enum ActivityBatchError: LocalizedError {
    case invalidCutoff
    case invalidItemDate(String)
    case repeatedCursor
    case partial(updated: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCutoff: "Could not verify activity snapshot time; no results were changed."
        case .invalidItemDate(let id): "Could not verify timestamp for \(id); no further results were changed."
        case .repeatedCursor: "Activity paging repeated a cursor; remaining results were not changed."
        case .partial(let updated, let total): "Updated \(updated) of \(total) results before the host returned a partial response."
        }
    }
}

@MainActor
final class ActivityViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case running, needsYou, justFinished, finished
        var id: String { rawValue }
        var wireValue: String {
            switch self {
            case .needsYou: "needs_you"
            case .justFinished: "just_finished"
            default: rawValue
            }
        }
        var title: String {
            switch self {
            case .running: "Running"
            case .needsYou: "Needs you"
            case .justFinished: "Just finished"
            case .finished: "Results"
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case all, day, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Any time"
            case .day: "Past 24 hours"
            case .week: "Past 7 days"
            case .month: "Past 30 days"
            }
        }
        var since: String? {
            guard self != .all else { return nil }
            let seconds: TimeInterval = self == .day ? 86_400 : self == .week ? 604_800 : 2_592_000
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date().addingTimeInterval(-seconds))
        }
    }

    @Published private(set) var page = ActivityWirePage()
    @Published private(set) var detail: ActivityWireItem?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var undoCount: Int?
    @Published private(set) var batchStatus: String?
    @Published private(set) var batchRunning = false
    @Published private(set) var showingCachedResults = false
    @Published private(set) var hasSuccessfulSnapshot = false
    @Published var tab: Tab { didSet { needsInitialTabChoice = false; resetSelectionForFilterChange(); if tab != .finished && !outcome.isEmpty { outcome = "" }; persist(); if !applyingInitialTabChoice { refreshAfterFrame() } } }
    @Published var search = "" { didSet { resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var outcome = "" { didSet { resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var workspaceID = "" { didSet { resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var period: Period { didSet { guard oldValue != period else { return }; resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var selectedID: String? { didSet { persist() } }
    @Published var scrollID: String? { didSet { persist() } }

    private let service: ActivityClient
    private let defaults: UserDefaults
    private var cursor: String?
    private var activeSince: String?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var undoSnapshot: [String: String?] = [:]
    private var undoCleared: [String] = []
    private var errorIsFromRefresh = false
    private var needsInitialTabChoice = false
    private var applyingInitialTabChoice = false
    private var scrollRestored = false
    private var eventSubscription: UUID?
    private var refreshInvalidationPending = false
    private var requestedTargetID: String?
    /// Only a notification route names its target explicitly. A selection restored from
    /// defaults is local convenience: when its row has moved section it is dropped quietly.
    private var requestedTargetIsExplicit = false

    init(router: AppCommandRouter, defaults: UserDefaults = .standard) {
        service = ActivityClient(router: router)
        self.defaults = defaults
        let restored = defaults.string(forKey: "activity.tab").flatMap(Tab.init(rawValue:))
        needsInitialTabChoice = restored == nil
        tab = restored ?? .running
        search = defaults.string(forKey: "activity.search") ?? ""
        outcome = restored == .finished ? (defaults.string(forKey: "activity.outcome") ?? "") : ""
        workspaceID = defaults.string(forKey: "activity.workspace") ?? ""
        period = Period(rawValue: defaults.string(forKey: "activity.period") ?? "all") ?? .all
        activeSince = period.since
        selectedID = defaults.string(forKey: "activity.selection")
        requestedTargetID = selectedID
        scrollID = defaults.string(forKey: "activity.scroll")
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(ActivityWirePage.self, from: data) {
            page = cached
            hasSuccessfulSnapshot = true
            cursor = cached.next_cursor
            if let selectedID { detail = cached.items.first(where: { $0.id == selectedID }) }
            showingCachedResults = true
        }
        subscribeToActivityInvalidations()
    }

    init(service: ActivityClient, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        let restored = defaults.string(forKey: "activity.tab").flatMap(Tab.init(rawValue:))
        needsInitialTabChoice = restored == nil
        tab = restored ?? .running
        search = defaults.string(forKey: "activity.search") ?? ""
        outcome = restored == .finished ? (defaults.string(forKey: "activity.outcome") ?? "") : ""
        workspaceID = defaults.string(forKey: "activity.workspace") ?? ""
        period = Period(rawValue: defaults.string(forKey: "activity.period") ?? "all") ?? .all
        activeSince = period.since
        selectedID = defaults.string(forKey: "activity.selection")
        requestedTargetID = selectedID
        scrollID = defaults.string(forKey: "activity.scroll")
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(ActivityWirePage.self, from: data) {
            page = cached
            hasSuccessfulSnapshot = true
            cursor = cached.next_cursor
            if let selectedID { detail = cached.items.first(where: { $0.id == selectedID }) }
            showingCachedResults = true
        }
        subscribeToActivityInvalidations()
    }

    deinit {
        task?.cancel()
        if let eventSubscription { EventBus.shared.unsubscribe(eventSubscription) }
    }

    private func subscribeToActivityInvalidations() {
        eventSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { [weak self] event in
            guard ["notification.created", "notification.read", "notification.dismissed", "bots.attention.changed", "bot.attention.updated", "bot.scheduler.updated", "operation.updated", "surface.updated", "agent.run.started", "agent.run.completed", "agent.run.failed", "agent.run.finished", "agent.run.cancelled", "agent.request.opened", "agent.request.resolved", "agent.user_input.requested", "agent.user_input.resolved"].contains(event.kind) else { return }
            Task { @MainActor [weak self] in self?.scheduleInvalidationRefresh() }
        }
    }

    private func scheduleInvalidationRefresh() {
        guard !refreshInvalidationPending else { return }
        refreshInvalidationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.refreshInvalidationPending = false
            self.refreshAfterFrame()
        }
    }

    private var cacheKey: String {
        "activity.page.\(tab.rawValue).\(workspaceID).\(outcome).\(period.rawValue).\(search)"
    }

    private func resetSelectionForFilterChange() {
        requestedTargetID = nil
        selectedID = nil
        scrollID = nil
        detail = nil
        scrollRestored = false
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(ActivityWirePage.self, from: data) {
            page = cached
            cursor = cached.next_cursor
            hasSuccessfulSnapshot = true
            showingCachedResults = true
        } else {
            page = ActivityWirePage()
            cursor = nil
            hasSuccessfulSnapshot = false
            showingCachedResults = false
        }
    }

    private func persist() {
        defaults.set(tab.rawValue, forKey: "activity.tab")
        defaults.set(search, forKey: "activity.search")
        defaults.set(outcome, forKey: "activity.outcome")
        defaults.set(workspaceID, forKey: "activity.workspace")
        defaults.set(period.rawValue, forKey: "activity.period")
        defaults.set(selectedID, forKey: "activity.selection")
        defaults.set(scrollID, forKey: "activity.scroll")
    }

    private func persistPage() {
        guard let data = try? JSONEncoder().encode(page) else { return }
        defaults.set(data, forKey: cacheKey)
        let stale = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("activity.page.") && $0 != cacheKey }
            .sorted()
        for key in stale.dropLast(7) { defaults.removeObject(forKey: key) }
    }

    func loadCached(_ cached: ActivityWirePage) {
        page = cached
        hasSuccessfulSnapshot = true
        cursor = cached.next_cursor
        if let selectedID { detail = cached.items.first(where: { $0.id == selectedID }) }
        showingCachedResults = true
    }

    func applyRoute(intent: NotificationRouteIntent) {
        tab = .finished
        workspaceID = intent.workspaceId?.value.uuidString ?? ""
        search = ""
        outcome = ""
        period = .all
        selectedID = nil
        scrollID = nil
        requestedTargetID = intent.activityItemId
        requestedTargetIsExplicit = intent.activityItemId != nil
        if let itemID = intent.activityItemId {
            selectedID = itemID
            scrollID = itemID
        }
        refreshAfterFrame()
    }

    func refreshAfterFrame() {
        task?.cancel()
        generation &+= 1
        let request = generation
        task = Task { @MainActor [weak self] in
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            // Ask for the depth already paged to in one request, so a refresh never truncates the list under the reader.
            let depth = min(max(self.page.items.count, Self.pageSize), Self.batchPageSize)
            self.cursor = nil
            self.activeSince = self.period.since
            self.loading = true
            if self.errorIsFromRefresh { self.error = nil }
            do {
                let params = Self.listParams(tab: self.tab, search: self.search, outcome: self.outcome, workspaceID: self.workspaceID, since: self.activeSince, limit: depth)
                let next = try Self.decodePage(try await self.service.list(params))
                guard !Task.isCancelled, self.generation == request else { return }
                let previous = self.page.items
                let openedDetail = self.detail
                self.page = next
                self.hasSuccessfulSnapshot = true
                if let selectedID = self.selectedID {
                    self.detail = next.items.first(where: { $0.id == selectedID })
                    // Opening a row marks it read, which drops it from Just finished;
                    // the open row stays in place until the user leaves it.
                    if self.detail == nil, self.tab == .justFinished, let openedDetail, openedDetail.id == selectedID {
                        let keptBefore = previous.prefix { $0.id != selectedID }.filter { kept in next.items.contains { $0.id == kept.id } }.count
                        self.page.items.insert(openedDetail, at: min(keptBefore, self.page.items.count))
                        self.detail = openedDetail
                    }
                } else {
                    self.detail = nil
                }
                if self.requestedTargetID == self.detail?.id { self.requestedTargetID = nil }
                self.showingCachedResults = false
                self.cursor = next.next_cursor
                self.persistPage()
                if let targetID = self.selectedID, self.detail == nil, self.requestedTargetID == targetID {
                    var cursors = Set<String>()
                    while !self.page.items.contains(where: { $0.id == targetID }), let pageCursor = self.cursor {
                        guard !Task.isCancelled, self.generation == request, cursors.insert(pageCursor).inserted else { return }
                        var pageParams = Self.listParams(tab: self.tab, search: self.search, outcome: self.outcome, workspaceID: self.workspaceID, since: self.activeSince)
                        pageParams["cursor"] = .string(pageCursor)
                        let targetPage = try Self.decodePage(try await self.service.list(pageParams))
                        guard !Task.isCancelled, self.generation == request else { return }
                        self.page.items += targetPage.items
                        self.cursor = targetPage.next_cursor
                        self.page.next_cursor = targetPage.next_cursor
                        self.page.generated_at = targetPage.generated_at
                        self.persistPage()
                        if let target = targetPage.items.first(where: { $0.id == targetID }) {
                            self.detail = target
                            self.requestedTargetID = nil
                            self.scrollID = targetID
                        }
                    }
                    guard !Task.isCancelled, self.generation == request else { return }
                    if self.detail == nil {
                        if self.requestedTargetIsExplicit {
                            // Stays until dismissed: the next invalidation refresh must not wipe it.
                            self.error = "Requested activity result was not found."
                            self.errorIsFromRefresh = false
                        } else {
                            self.selectedID = nil
                            self.scrollID = nil
                        }
                    }
                    // Search once. A target left armed was paged for and reported again on every refresh.
                    self.requestedTargetID = nil
                    self.requestedTargetIsExplicit = false
                } else if let selectedID = self.selectedID, self.detail == nil {
                    self.selectedID = nil
                    self.scrollID = nil
                }
                if self.needsInitialTabChoice {
                    self.needsInitialTabChoice = false
                    let preferred: Tab = next.counts.needs_you > 0 ? .needsYou : (next.counts.running > 0 ? .running : .finished)
                    if preferred != self.tab {
                        self.applyingInitialTabChoice = true
                        self.tab = preferred
                        self.applyingInitialTabChoice = false
                        self.refreshAfterFrame()
                        return
                    } else { self.persist() }
                }
            } catch {
                guard self.generation == request else { return }
                self.error = error.localizedDescription
                self.errorIsFromRefresh = true
            }
            if self.generation == request { self.loading = false; self.task = nil }
        }
    }

    func loadMore() {
        guard let cursor, !loading else { return }
        let request = generation
        let pageCursor = cursor
        loading = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var params = Self.listParams(tab: self.tab, search: self.search, outcome: self.outcome, workspaceID: self.workspaceID, since: self.activeSince)
                params["cursor"] = .string(pageCursor)
                let next = try Self.decodePage(try await self.service.list(params))
                guard self.generation == request else { return }
                self.page.items += next.items
                self.cursor = next.next_cursor
                self.page.next_cursor = next.next_cursor
                self.page.generated_at = next.generated_at
                self.persistPage()
            } catch {
                if self.generation == request { self.error = error.localizedDescription; self.errorIsFromRefresh = true }
            }
            if self.generation == request { self.loading = false; self.task = nil }
        }
    }

    func openDetail(_ item: ActivityWireItem) {
        requestedTargetID = nil
        selectedID = item.id
        scrollID = item.id
        detail = item
    }

    /// Leaves the pushed detail of a narrow window. The scroll anchor stays, so the list
    /// returns to the same place and the same row can be opened again.
    func closeDetail() {
        requestedTargetID = nil
        selectedID = nil
        detail = nil
        scrollRestored = false
    }

    func restoreScrollAnchor() -> String? {
        defer { scrollRestored = true }
        return scrollID ?? selectedID
    }

    func didDisplay(_ id: String) {
        if scrollRestored { scrollID = id }
    }

    func detailPresented(_ item: ActivityWireItem) {
        guard detail?.id == item.id, item.isUnread else { return }
        setViewed(item, viewed: true)
    }

    func markRead(_ item: ActivityWireItem) { setViewed(item, viewed: true) }
    func markUnread(_ item: ActivityWireItem) { setViewed(item, viewed: false) }

    /// Filters captured on the click turn, so a bulk action never follows a later filter change.
    private struct BatchScope {
        let params: [String: JSONValue]
        let clickTime: Date
    }

    private var batchScope: BatchScope {
        BatchScope(params: Self.listParams(tab: tab, search: search, outcome: outcome, workspaceID: workspaceID, since: period.since, limit: Self.batchPageSize), clickTime: Date())
    }

    /// Pages the whole scope from one frozen snapshot. Items that arrived after the click stay out.
    private func collect(_ scope: BatchScope, where matches: (ActivityWireItem) -> Bool) async throws -> [ActivityWireItem] {
        var params = scope.params
        var result = try Self.decodePage(try await service.list(params))
        guard let generatedAt = result.generated_at.flatMap(Self.parseDate) else { throw ActivityBatchError.invalidCutoff }
        let cutoff = min(scope.clickTime, generatedAt)
        var cursors = Set<String>()
        var seen = Set<String>()
        var items: [ActivityWireItem] = []
        while true {
            for item in result.items where matches(item) {
                guard let time = Self.parseDate(item.occurred_at) else { throw ActivityBatchError.invalidItemDate(item.id) }
                if time <= cutoff, seen.insert(item.id).inserted { items.append(item) }
            }
            guard let next = result.next_cursor else { break }
            guard cursors.insert(next).inserted else { throw ActivityBatchError.repeatedCursor }
            params["cursor"] = .string(next)
            result = try Self.decodePage(try await service.list(params))
        }
        return items
    }

    private func beginBatch(_ status: String) {
        batchRunning = true
        batchStatus = status
        error = nil
        undoSnapshot = [:]
        undoCleared = []
        undoCount = nil
    }

    func markCurrentResultsSeen() {
        guard !batchRunning else { return }
        beginBatch("Collecting unread results…")
        let scope = batchScope
        Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            var updated = Set<String>()
            do {
                let items = try await self.collect(scope) { $0.isUnread }
                guard !items.isEmpty else {
                    self.batchStatus = "No unread results match this filter."
                    self.batchRunning = false
                    return
                }
                let snapshots = Dictionary(items.map { ($0.id, $0.viewed_at) }, uniquingKeysWith: { first, _ in first })
                let ids = snapshots.keys.sorted()
                for start in stride(from: 0, to: ids.count, by: 200) {
                    let chunk = Array(ids[start..<min(start + 200, ids.count)])
                    let response = try self.service.setViewed(["item_ids": .array(chunk.map(JSONValue.string)), "viewed": .bool(true)])
                    let chunkUpdated = Self.updatedIDs(response).intersection(chunk)
                    updated.formUnion(chunkUpdated)
                    self.undoSnapshot = snapshots.filter { updated.contains($0.key) }
                    self.undoCount = updated.count
                    self.applyViewed(chunkUpdated, viewedAt: Self.timestamp(Date()))
                    if chunkUpdated.count != chunk.count { throw ActivityBatchError.partial(updated: updated.count, total: ids.count) }
                }
                self.batchStatus = "Marked \(updated.count) as read."
                self.refreshAfterFrame()
            } catch {
                if !self.undoSnapshot.isEmpty {
                    self.batchStatus = "Marked \(self.undoSnapshot.count) as read before a failure. Undo restores them."
                }
                self.fail(error)
            }
            self.batchRunning = false
        }
    }

    /// Clears every clearable item in the current filter from Needs you. Items the host no
    /// longer considers open are skipped, so the status reports what actually changed.
    func clearCurrentNeedsYou() {
        guard !batchRunning else { return }
        beginBatch("Collecting alerts to dismiss…")
        let scope = batchScope
        Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            do {
                let items = try await self.collect(scope) { $0.isClearable }
                guard !items.isEmpty else {
                    self.batchStatus = "Nothing to dismiss in this filter."
                    self.batchRunning = false
                    return
                }
                for start in stride(from: 0, to: items.count, by: 200) {
                    let chunk = Array(items[start..<min(start + 200, items.count)])
                    let cleared = try self.clear(chunk)
                    self.applyCleared(cleared)
                }
                self.batchStatus = self.undoCleared.isEmpty ? "No alerts needed dismissal." : "Dismissed \(self.undoCleared.count) from Needs you."
                self.refreshAfterFrame()
            } catch {
                if !self.undoCleared.isEmpty {
                    self.batchStatus = "Dismissed \(self.undoCleared.count) before a failure. Undo restores them."
                }
                self.fail(error)
            }
            self.batchRunning = false
        }
    }

    /// Acknowledges up to 200 items and marks the unread ones read, recording both for Undo.
    private func clear(_ items: [ActivityWireItem]) throws -> Set<String> {
        let ids = items.map(\.id)
        let response = try service.acknowledge(["item_ids": .array(ids.map(JSONValue.string)), "acknowledged": .bool(true)])
        let cleared = Self.updatedIDs(response).intersection(ids)
        undoCleared += ids.filter(cleared.contains)
        undoCount = undoCleared.count
        let unread = items.filter { cleared.contains($0.id) && $0.isUnread }
        guard !unread.isEmpty else { return cleared }
        let unreadIDs = unread.map(\.id)
        let viewed = Self.updatedIDs(try service.setViewed(["item_ids": .array(unreadIDs.map(JSONValue.string)), "viewed": .bool(true)])).intersection(unreadIDs)
        for item in unread where viewed.contains(item.id) { undoSnapshot[item.id] = item.viewed_at }
        if viewed.count != unread.count { throw ActivityBatchError.partial(updated: viewed.count, total: unread.count) }
        return cleared
    }

    func acknowledge(_ item: ActivityWireItem) {
        guard item.isClearable else { return }
        do {
            _ = try service.acknowledge(["item_id": .string(item.id)])
        } catch {
            fail(error)
            return
        }
        undoSnapshot = [:]
        undoCleared = [item.id]
        undoCount = 1
        batchStatus = "Dismissed from Needs you."
        applyCleared([item.id])
        do {
            if item.isUnread {
                let viewed = Self.updatedIDs(try service.setViewed(["item_ids": .array([.string(item.id)]), "viewed": .bool(true)]))
                guard viewed.contains(item.id) else { throw ActivityBatchError.partial(updated: 0, total: 1) }
                undoSnapshot[item.id] = item.viewed_at
            }
            refreshAfterFrame()
        } catch { fail(error) }
    }

    private func setViewed(_ item: ActivityWireItem, viewed: Bool) {
        guard item.isMarkable else { return }
        do {
            let response = try service.setViewed(["item_ids": .array([.string(item.id)]), "viewed": .bool(viewed)])
            guard Self.updatedIDs(response).contains(item.id) else { throw ActivityBatchError.partial(updated: 0, total: 1) }
            applyViewed([item.id], viewedAt: viewed ? Self.timestamp(Date()) : nil)
            refreshAfterFrame()
        } catch { fail(error) }
    }

    /// Mirrors a mutation the host already confirmed, so the row answers before the refresh returns.
    private func applyViewed(_ ids: Set<String>, viewedAt: String?) {
        guard !ids.isEmpty else { return }
        for index in page.items.indices where ids.contains(page.items[index].id) { page.items[index].viewed_at = viewedAt }
        if let current = detail, ids.contains(current.id) { detail?.viewed_at = viewedAt }
    }

    private func applyCleared(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        page.counts.needs_you = max(0, page.counts.needs_you - ids.count)
        guard tab == .needsYou else {
            for index in page.items.indices where ids.contains(page.items[index].id) { page.items[index].needs_action = false }
            if let current = detail, ids.contains(current.id) { detail?.needs_action = false }
            return
        }
        // Advance to the neighbor so triage continues without re-aiming.
        var successor: ActivityWireItem?
        let visual = listSections.flatMap(\.items)
        if let selectedID, ids.contains(selectedID), let index = visual.firstIndex(where: { $0.id == selectedID }) {
            successor = visual[(index + 1)...].first { !ids.contains($0.id) }
                ?? visual[..<index].last { !ids.contains($0.id) }
        }
        let selectionCleared = selectedID.map(ids.contains) ?? false
        page.items.removeAll { ids.contains($0.id) }
        guard selectionCleared else { return }
        if let successor { openDetail(successor) } else { selectedID = nil; scrollID = nil; detail = nil }
    }

    private func fail(_ error: Error) {
        self.error = error.localizedDescription
        errorIsFromRefresh = false
    }

    func undoLastAction() {
        let viewedSnapshot = undoSnapshot
        let cleared = undoCleared
        guard !viewedSnapshot.isEmpty || !cleared.isEmpty else { return }
        var reopened = Set<String>()
        var restored = Set<String>()
        do {
            for start in stride(from: 0, to: cleared.count, by: 200) {
                let chunk = Array(cleared[start..<min(start + 200, cleared.count)])
                let response = try service.acknowledge(["item_ids": .array(chunk.map(JSONValue.string)), "acknowledged": .bool(false)])
                let chunkReopened = Self.updatedIDs(response).intersection(chunk)
                reopened.formUnion(chunkReopened)
                if chunkReopened.count != chunk.count { throw ActivityBatchError.partial(updated: reopened.count, total: cleared.count) }
            }
            let ids = viewedSnapshot.keys.sorted()
            for start in stride(from: 0, to: ids.count, by: 200) {
                let chunk = Array(ids[start..<min(start + 200, ids.count)])
                let restore = Dictionary(uniqueKeysWithValues: chunk.map { id in (id, (viewedSnapshot[id] ?? nil).map(JSONValue.string) ?? .null) })
                let response = try service.setViewed(["item_ids": .array(chunk.map(JSONValue.string)), "viewed": .bool(false), "restore_viewed_at": .object(restore)])
                let chunkRestored = Self.updatedIDs(response).intersection(chunk)
                restored.formUnion(chunkRestored)
                if chunkRestored.count != chunk.count { throw ActivityBatchError.partial(updated: restored.count, total: ids.count) }
            }
            undoSnapshot.removeAll()
            undoCleared.removeAll()
            undoCount = nil
            batchStatus = cleared.isEmpty ? "Restored \(restored.count) to unread." : "Restored \(reopened.count) to Needs you."
            refreshAfterFrame()
        } catch {
            undoCleared = cleared.filter { !reopened.contains($0) }
            undoSnapshot = viewedSnapshot.filter { !restored.contains($0.key) }
            let remaining = Set(undoCleared).union(undoSnapshot.keys).count
            undoCount = remaining == 0 ? nil : remaining
            if remaining > 0 { batchStatus = "Undo stopped early; \(remaining) still need Undo." }
            fail(error)
        }
    }

    func dismissStatus() {
        batchStatus = nil
        undoSnapshot.removeAll()
        undoCleared.removeAll()
        undoCount = nil
    }

    var hasActiveFilters: Bool { !search.isEmpty || !workspaceID.isEmpty || !outcome.isEmpty || period != .all }

    func clearFilters() {
        if !search.isEmpty { search = "" }
        if !workspaceID.isEmpty { workspaceID = "" }
        if !outcome.isEmpty { outcome = "" }
        if period != .all { period = .all }
    }

    private static func listParams(tab: Tab, search: String, outcome: String, workspaceID: String, since: String?, limit: Int = pageSize) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["section": .string(tab.wireValue), "search": .string(search), "limit": .number(Double(limit))]
        if !outcome.isEmpty { params["outcome"] = .string(outcome) }
        if !workspaceID.isEmpty { params["workspace_id"] = .string(workspaceID) }
        if let since { params["since"] = .string(since) }
        return params
    }

    private static func decodePage(_ value: JSONValue) throws -> ActivityWirePage {
        try JSONDecoder().decode(ActivityWirePage.self, from: JSONEncoder().encode(value))
    }

    private static func updatedIDs(_ value: JSONValue) -> Set<String> {
        Set(value.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    private static let pageSize = 50
    /// Host cap per request. A bulk action reads its whole filter in pages this large:
    /// every page recomputes the full Activity projection on the host, so 50 at a time
    /// turned 1,400 results into 28 full passes.
    private static let batchPageSize = 500
    // Rows parse a timestamp per render: the format styles are the fast path, and the shared
    // formatters (documented thread-safe) keep the old result for anything the styles reject.
    nonisolated private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    nonisolated private static let plainDateStyle = Date.ISO8601FormatStyle()
    nonisolated(unsafe) private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainDateFormatter = ISO8601DateFormatter()

    nonisolated fileprivate static func parseDate(_ value: String) -> Date? {
        (try? fractionalDateStyle.parse(value)) ?? (try? plainDateStyle.parse(value))
            ?? fractionalDateFormatter.date(from: value) ?? plainDateFormatter.date(from: value)
    }

    private static func timestamp(_ date: Date) -> String { fractionalDateFormatter.string(from: date) }
}

/// Message footer for a Bot conversation whose transcript has no open workspace.
private struct ActivityBotComposer: View {
    let target: ActivityBotTarget
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error).font(DS.Font.caption).foregroundColor(DS.Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.xl)
            }
            AgentChatComposerBar(
                text: $text,
                placeholder: "Message the Bot",
                sendEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                runActive: target.isRunActive(),
                onSend: send,
                onStop: stop,
                composerIdentifier: "activity.composer.input",
                sendIdentifier: "activity.composer.send",
                showsAttach: false
            )
        }
    }

    private func send() {
        do {
            try target.send(text)
            text = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() {
        do { try target.stop() } catch { self.error = error.localizedDescription }
    }
}

struct ActivityRootView: View {
    @StateObject private var model: ActivityViewModel
    @State private var narrowDetail = false
    @State private var searchFocusRequest = false
    /// The one live conversation the detail pane holds; rebuilt only when the selected thread changes.
    @State private var conversation: (threadID: String, host: ActivityConversation)?
    let openThread: (ActivityWireItem) -> Void
    let openEvidence: (ActivityWireItem, String?) -> Void
    private let makeConversation: (ActivityWireItem) -> ActivityConversation?
    private let workspaceOptions: () -> [(id: String, name: String)]
    /// Whether a workspace is still open in this Mac's layout; a thread outside one has nowhere to open.
    private let isWorkspaceOpen: (String) -> Bool
    /// The Bot behind an item, so its row shows the Bot's avatar instead of the status icon.
    private let botForItem: (ActivityWireItem) -> BotDefinition?
    /// The workspace's sidebar folder color; nil keeps the neutral folder.
    private let workspaceColor: (String) -> Color?
    let route: NotificationRouteIntent?
    let consumeRoute: () -> Void

    /// Below this width the list and the detail take turns instead of sitting side by side.
    private static let compactWidth: CGFloat = 720

    init(router: AppCommandRouter, route: NotificationRouteIntent? = nil, consumeRoute: @escaping () -> Void = {}, openThread: @escaping (ActivityWireItem) -> Void = { _ in }, openEvidence: @escaping (ActivityWireItem, String?) -> Void = { _, _ in }) {
        _model = StateObject(wrappedValue: ActivityViewModel(router: router))
        self.openThread = openThread
        self.openEvidence = openEvidence
        makeConversation = { [weak router] item in router?.makeActivityConversation(item) }
        self.route = route
        self.consumeRoute = consumeRoute
        workspaceOptions = { router.activityWorkspaceOptions }
        isWorkspaceOpen = { [weak router] id in router?.activityWorkspaceIsOpen(id) ?? false }
        workspaceColor = { [weak router] id in router?.activityWorkspaceColor(id) }
        // In-memory only (roster + linked-thread cache): rows re-render often and must not read SQLite.
        botForItem = { [weak router] item in
            guard let router, let store = router.context?.botStore else { return nil }
            return ActivityBotResolver.botID(for: item, store: store).flatMap { id in router.botsViewModel?.bots.first { $0.id == id } }
        }
    }

    /// Renders a prepared model without a router: offscreen layout proofs and worst-case data.
    init(model: ActivityViewModel, workspaceOptions: @escaping () -> [(id: String, name: String)] = { [] }, isWorkspaceOpen: @escaping (String) -> Bool = { _ in true }, makeConversation: @escaping (ActivityWireItem) -> ActivityConversation? = { _ in nil }, botForItem: @escaping (ActivityWireItem) -> BotDefinition? = { _ in nil }, workspaceColor: @escaping (String) -> Color? = { _ in nil }) {
        _model = StateObject(wrappedValue: model)
        openThread = { _ in }
        openEvidence = { _, _ in }
        self.makeConversation = makeConversation
        route = nil
        consumeRoute = {}
        self.workspaceOptions = workspaceOptions
        self.isWorkspaceOpen = isWorkspaceOpen
        self.botForItem = botForItem
        self.workspaceColor = workspaceColor
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error { errorBanner(error) }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            GeometryReader { proxy in
                if proxy.size.width < Self.compactWidth {
                    if narrowDetail, let item = model.detail { compactDetail(item) } else { list }
                } else {
                    HStack(spacing: 0) {
                        list.frame(width: min(max(proxy.size.width * 0.36, 340), 460))
                        Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
                        if let item = model.detail {
                            detailPane(item)
                        } else {
                            DSEmptyState(icon: "rectangle.righthalf.inset.filled", title: "Nothing selected", subtitle: "Select an item to see its result and what you can do next.")
                        }
                    }
                }
            }
            if let status = model.batchStatus { statusStrip(status).transition(.opacity) }
        }
        .animation(DS.Motion.micro, value: model.batchStatus != nil)
        .frame(minWidth: 320, minHeight: 420)
        .background(DS.Palette.bg)
        .onAppear {
            if let route { apply(route) }
            else { model.refreshAfterFrame() }
            syncConversation()
        }
        .onDisappear {
            conversation?.host.close()
            conversation = nil
        }
        .onChange(of: route) { _, next in
            if let next { apply(next) }
        }
        .onChange(of: model.detail?.thread_id) { _, _ in syncConversation() }
    }

    /// Holds the conversation of the selected thread, built on the selection turn so it
    /// mounts with the click. The one it replaces stops observing its runs.
    private func syncConversation() {
        let threadID = model.detail?.thread_id
        guard conversation?.threadID != threadID else { return }
        conversation?.host.close()
        conversation = model.detail.flatMap { item in
            threadID.flatMap { id in makeConversation(item).map { (id, $0) } }
        }
    }

    private func apply(_ route: NotificationRouteIntent) {
        model.applyRoute(intent: route)
        consumeRoute()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Text("Activity").font(DS.Font.title.weight(.semibold)).foregroundColor(DS.Palette.text).lineLimit(1)
                Spacer(minLength: DS.Space.md)
                // Fixed slot: the spinner must not move the header when it appears.
                ZStack {
                    if model.loading || model.batchRunning { DSBusySpinner(label: "Updating activity", identifier: "activity.busy") }
                }.frame(width: 16, height: 16)
                bulkActions
            }
            // Wide panes keep tabs and filters on one row; narrow ones stack them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.md) {
                    tabs
                    Spacer(minLength: DS.Space.lg)
                    searchField.frame(minWidth: 160, maxWidth: 260)
                    filterMenus
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: DS.Space.sm) { tabs } }
                    searchField.frame(maxWidth: .infinity)
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: DS.Space.sm) { filterMenus } }
                }
            }
        }.padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.lg)
    }

    private var searchField: some View {
        SidebarSearchField(placeholder: "Search title or summary", text: $model.search, focusRequest: $searchFocusRequest, accessibilityIdentifier: "activity.search")
    }

    @ViewBuilder
    private var filterMenus: some View {
        filterMenu(
            icon: "folder", title: workspaces.first { $0.id == model.workspaceID }?.name ?? "All workspaces",
            active: !model.workspaceID.isEmpty, label: "Workspace", identifier: "activity.filter.workspace"
        ) {
            menuOption("All workspaces", selected: model.workspaceID.isEmpty) { model.workspaceID = "" }
            Divider()
            ForEach(workspaces, id: \.id) { workspace in
                menuOption(workspace.name, selected: model.workspaceID == workspace.id) { model.workspaceID = workspace.id }
            }
        }
        filterMenu(icon: "clock", title: model.period.title, active: model.period != .all, label: "Period", identifier: "activity.filter.period") {
            ForEach(ActivityViewModel.Period.allCases) { period in
                menuOption(period.title, selected: model.period == period) { model.period = period }
            }
        }
        if model.tab == .finished {
            filterMenu(icon: "line.3.horizontal.decrease", title: Self.outcomeTitle(model.outcome), active: !model.outcome.isEmpty,
                       label: "Outcome", identifier: "activity.filter.outcome") {
                ForEach(Self.outcomes, id: \.value) { outcome in
                    menuOption(outcome.title, selected: model.outcome == outcome.value) { model.outcome = outcome.value }
                }
            }
        }
    }

    private static let outcomes: [(value: String, title: String)] = [
        ("", "All outcomes"), ("completed", "Completed"), ("failed", "Failed"), ("interrupted", "Interrupted"), ("stopped", "Stopped by you"),
    ]
    private static func outcomeTitle(_ value: String) -> String { outcomes.first { $0.value == value }?.title ?? "All outcomes" }

    /// Composer-style capsule menu: an active filter is tinted so it is visible at a glance.
    private func filterMenu<Content: View>(icon: String, title: String, active: Bool, label: String, identifier: String, @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: {
            AgentComposerCapsule(style: active ? .tinted(DS.Palette.accent) : .raised, foreground: active ? DS.Palette.accent : DS.Palette.textSecondary) {
                AgentComposerCapsuleLabel(icon: icon, title: title, chevron: true).frame(maxWidth: 180)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Filter by \(label.lowercased())")
        .accessibilityLabel("\(label): \(title)")
        .accessibilityIdentifier(identifier)
    }

    private func menuOption(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Image(systemName: "checkmark") }
            Text(title)
        }
    }

    private var tabs: some View {
        ForEach(ActivityViewModel.Tab.allCases) { tab in
            AgentListFilterChip(title: tab.title, count: count(for: tab), selected: model.tab == tab, identifier: "activity.tab.\(tab.rawValue)") { model.tab = tab }
                .fixedSize()
        }
    }

    @ViewBuilder
    private var bulkActions: some View {
        // One bulk action per tab: reading never empties Needs you, so offering it there only misleads.
        if model.tab == .finished || model.tab == .justFinished {
            Button("Mark all as read") { model.markCurrentResultsSeen() }
                .buttonStyle(DSSecondaryButtonStyle()).disabled(model.batchRunning || !model.hasUnreadResults).fixedSize()
                .help(model.hasUnreadResults ? "Marks every result in this filter as read. Nothing is removed." : "Every result in this filter is already read.")
                .accessibilityIdentifier("activity.markAllRead")
        }
        if model.tab == .needsYou {
            Button("Dismiss all") { model.clearCurrentNeedsYou() }
                .buttonStyle(DSSecondaryButtonStyle()).disabled(model.batchRunning || model.page.counts.needs_you == 0).fixedSize()
                .help("Dismisses alerts in this filter and marks results read. Pending approvals and questions still wait in their conversations.")
                .accessibilityIdentifier("activity.clearAll")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").font(DS.Font.body).foregroundColor(DS.Palette.danger).accessibilityHidden(true)
            Text(model.showingCachedResults ? "Showing saved results. Update failed: \(error)" : "Update failed: \(error)")
                .font(DS.Font.bodyDense).foregroundColor(DS.Palette.text).lineLimit(3)
            Spacer(minLength: DS.Space.md)
            Button("Retry") { model.refreshAfterFrame() }.buttonStyle(DSSecondaryButtonStyle())
            DSIconButton("xmark", help: "Dismiss error") { model.dismissError() }.packed()
        }
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.md)
        .background(DS.Palette.danger.opacity(0.12))
        .accessibilityIdentifier("activity.error")
    }

    private func statusStrip(_ status: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Text(status).font(DS.Font.bodyDense).foregroundColor(DS.Palette.text).lineLimit(2)
            Spacer(minLength: DS.Space.md)
            if model.undoCount != nil {
                Button("Undo") { model.undoLastAction() }
                    .buttonStyle(DSSecondaryButtonStyle()).disabled(model.batchRunning)
                    .accessibilityIdentifier("activity.undo")
            }
            DSIconButton("xmark", help: "Dismiss") { model.dismissStatus() }.packed()
        }
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.md)
        .background(DS.Palette.surfaceOverlay)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline) }
        .accessibilityIdentifier("activity.status")
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedID }, set: { id in
            guard let id, let item = model.page.items.first(where: { $0.id == id }) else { return }
            model.openDetail(item)
            narrowDetail = true
        })
    }

    @ViewBuilder
    private var list: some View {
        if model.page.items.isEmpty {
            if model.loading || model.error != nil || !model.hasSuccessfulSnapshot {
                // No safe cache for this filter yet: hold the layout, the header owns progress and errors.
                DS.Palette.bg.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hasActiveFilters {
                DSEmptyState(icon: "magnifyingglass", title: "No matches", subtitle: "Nothing in \(model.tab.title) matches this search and these filters.") {
                    Button("Clear filters") { model.clearFilters() }.buttonStyle(DSSecondaryButtonStyle())
                }
            } else {
                emptyState
            }
        } else {
            ScrollViewReader { proxy in
                List(selection: selection) {
                    ForEach(model.listSections) { section in
                        Section {
                            ForEach(section.items) { item in activityRow(item, showsWorkspace: false) }
                        } header: {
                            sectionHeader(section.title, count: section.items.count, workspaceID: section.id)
                        }
                    }
                    if model.cursorAvailable { loadMoreRow }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).background(DS.Palette.bg)
                .accessibilityIdentifier("activity.list")
                .onDeleteCommand { if let item = model.detail, item.isClearable { model.acknowledge(item) } }
                .onAppear { let anchor = model.restoreScrollAnchor(); if let anchor { proxy.scrollTo(anchor, anchor: .center) } }
                .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    /// Workspace header: the sidebar's folder in the workspace color, on the raised band the
    /// pinned header uses, so every header reads the same whether pinned or not.
    private func sectionHeader(_ title: String, count: Int?, workspaceID: String) -> some View {
        WorkspaceSectionHeader(title: title, count: count, hasWorkspace: !workspaceID.isEmpty, color: workspaceColor(workspaceID))
            .listRowInsets(EdgeInsets())
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.tab {
        case .running: DSEmptyState(icon: "moon.zzz", title: "Nothing running", subtitle: "Agent runs and project scripts in progress appear here.")
        case .needsYou: DSEmptyState(icon: "checkmark.circle", title: "Nothing needs you", subtitle: "Approvals, questions, and runs that failed and were not retried show up here.")
        case .justFinished: DSEmptyState(icon: "checkmark.seal", title: "You're caught up", subtitle: "Runs that finish show up here until you open them.")
        case .finished: DSEmptyState(icon: "tray", title: "No results yet", subtitle: "Each conversation's latest finished run shows up here.")
        }
    }

    private var loadMoreRow: some View {
        HStack(spacing: DS.Space.md) {
            Text("Showing \(model.page.items.count) of \(count(for: model.tab))")
                .font(DS.Font.caption).monospacedDigit().foregroundColor(DS.Palette.textSecondary)
            Spacer()
            Button(model.loading ? "Loading…" : "Load more") { model.loadMore() }
                .buttonStyle(DSSecondaryButtonStyle()).disabled(model.loading)
        }
        .padding(.vertical, DS.Space.sm)
        .listRowSeparator(.hidden)
    }

    private func activityRow(_ item: ActivityWireItem, showsWorkspace: Bool) -> some View {
        ActivityRow(
            item: item,
            bot: botForItem(item),
            toggleRead: { item.isUnread ? model.markRead(item) : model.markUnread(item) },
            clear: { model.acknowledge(item) },
            open: canOpen(item) ? { openThread(item) } : nil,
            openLabel: openLabel(item),
            showsWorkspace: showsWorkspace
        )
        .id(item.id)
        .listRowSeparatorTint(DS.Palette.line)
        .onAppear { model.didDisplay(item.id) }
    }

    private func compactDetail(_ item: ActivityWireItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { narrowDetail = false; model.closeDetail() } label: { Label("Activity", systemImage: "chevron.left") }
                    .buttonStyle(DSSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
            }.padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.md)
            detailPane(item)
        }
    }

    /// A chat opens as its conversation; anything without a thread keeps the summary.
    @ViewBuilder
    private func detailPane(_ item: ActivityWireItem) -> some View {
        if let conversation, conversation.threadID == item.thread_id {
            VStack(spacing: 0) {
                conversationHeader(item)
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                AgentAppView(
                    vm: conversation.host.viewModel,
                    layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: false, showsComposer: conversation.host.showsComposer)
                )
                .id(conversation.threadID)
                if !conversation.host.showsComposer, let target = conversation.host.botTarget {
                    ActivityBotComposer(target: target)
                }
            }
            .task(id: item.id) { model.detailPresented(item) }
            .accessibilityIdentifier("activity.conversation")
        } else {
            detailView(item)
        }
    }

    /// One compact bar: title and facts on the left, secondary actions on the right, so the
    /// conversation and its composer get the height.
    private func conversationHeader(_ item: ActivityWireItem) -> some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(item.displayTitle).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text).lineLimit(1).help(item.displayTitle)
                HStack(spacing: DS.Space.sm) {
                    DSPill(item.statusLabel, tone: ActivityStatusStyle.tone(item.state))
                    let facts = ([item.occurredDate.map(ActivityTimeLabel.full)] + [item.workspace_name, item.provider, item.origin_label])
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !facts.isEmpty {
                        Text(facts).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(1).truncationMode(.tail).help(facts)
                    }
                }
                attentionGuidance(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Space.sm) {
                if canOpen(item) {
                    Button(openLabel(item)) { openThread(item) }.buttonStyle(DSSecondaryButtonStyle())
                }
                if canOpen(item), canViewChanges(item) {
                    Button("View changes") { openEvidence(item, nil) }.buttonStyle(DSSecondaryButtonStyle())
                }
                if item.isClearable {
                    Button("Dismiss") { model.acknowledge(item) }.buttonStyle(DSSecondaryButtonStyle())
                        .help("Dismisses this alert without answering requests or deleting results.")
                }
                if item.isMarkable, !item.isNew {
                    Button("Mark as unread") { model.markUnread(item) }.buttonStyle(DSSecondaryButtonStyle())
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.md)
    }

    private func detailView(_ item: ActivityWireItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Text(item.displayTitle).font(DS.Font.title2).foregroundColor(DS.Palette.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.md) {
                        DSPill(item.statusLabel, tone: ActivityStatusStyle.tone(item.state))
                        if let date = item.occurredDate {
                            Text(ActivityTimeLabel.full(date)).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        }
                        if let duration = item.durationLabel {
                            Text("Duration \(duration)").font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        }
                    }
                }
                detailActions(item)
                detailFacts(item)
                if item.kind != "request" || (item.summary != nil && item.summary != item.attentionInstruction) {
                    detailSection(item.kind == "agent" ? "Agent summary" : "Result") {
                        Text(item.summary ?? "No summary available for this run.").font(DS.Font.body).foregroundColor(DS.Palette.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = item.error, !error.isEmpty {
                    detailSection("Error") {
                        Text(error).font(DS.Font.bodyDense).foregroundColor(DS.Palette.danger)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(DS.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Palette.danger.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    }
                }
                if !item.changed_files.isEmpty {
                    detailSection("Changes") {
                        ForEach(item.changed_files, id: \.self) { path in
                            if canOpen(item), canViewChanges(item) {
                                Button { openEvidence(item, path) } label: {
                                    Text(path).font(DS.Font.monoSmall).lineLimit(1).truncationMode(.middle)
                                }.buttonStyle(.link).help(path).accessibilityLabel("View \(path)")
                            } else {
                                Text(path).font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                                    .lineLimit(1).truncationMode(.middle).help(path)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.xxxl)
        }
        .task(id: item.id) { model.detailPresented(item) }
    }

    @ViewBuilder
    private func detailActions(_ item: ActivityWireItem) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                if canOpen(item) {
                    Button(openLabel(item)) { openThread(item) }.buttonStyle(DSPrimaryButtonStyle())
                }
                if canOpen(item), canViewChanges(item) {
                    Button("View changes") { openEvidence(item, nil) }.buttonStyle(DSSecondaryButtonStyle())
                }
                if item.isClearable {
                    Button("Dismiss") { model.acknowledge(item) }.buttonStyle(DSSecondaryButtonStyle())
                        .help(item.kind == "request" ? "Removes this from Needs you. The request stays in the bot's conversation." : "Removes this from Needs you. The result stays in Results.")
                }
                if item.isMarkable, !item.isNew {
                    Button("Mark as unread") { model.markUnread(item) }.buttonStyle(DSSecondaryButtonStyle())
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                }
            }
            if item.thread_id != nil, !canOpen(item) {
                Text("This conversation can't be opened: its workspace is closed or no longer exists.")
                    .font(DS.Font.bodyDense).foregroundColor(DS.Palette.textSecondary)
            }
            attentionGuidance(item)
        }
    }

    @ViewBuilder
    private func attentionGuidance(_ item: ActivityWireItem) -> some View {
        if let instruction = item.attentionInstruction {
            Text(instruction).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.attentionInstruction")
        }
    }

    @ViewBuilder
    private func detailFacts(_ item: ActivityWireItem) -> some View {
        let facts = [("Workspace", item.workspace_name), ("Provider", item.provider), ("Origin", item.origin_label)]
            .compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
        if !facts.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.sm) {
                ForEach(facts, id: \.0) { label, value in
                    GridRow {
                        Text(label).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        Text(value).font(DS.Font.body).foregroundColor(DS.Palette.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(title).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
            content()
        }
    }

    private func canOpen(_ item: ActivityWireItem) -> Bool {
        if item.id.hasPrefix("scheduled-occurrence:") { return true }
        if item.bot_id != nil || item.surface_id != nil || item.notification_id != nil { return true }
        // A thread no bot owns opens only into its workspace, which must still be open here.
        return item.thread_id != nil && item.workspace_id.map(isWorkspaceOpen) == true
    }

    private func canViewChanges(_ item: ActivityWireItem) -> Bool {
        item.checkpoint_turn_count != nil && item.thread_id != nil && item.workspace_id != nil && item.run_id != nil
    }

    private func openLabel(_ item: ActivityWireItem) -> String {
        if item.id.hasPrefix("scheduled-occurrence:") { return "Open Schedule Tasks" }
        if item.state == "waiting_answer" { return "Reply" }
        if item.state == "waiting_approval" { return "Review request" }
        if item.bot_id != nil { return "Open bot" }
        if item.thread_id != nil { return "Open conversation" }
        return item.surface_id != nil ? "Open terminal" : "Open destination"
    }

    private var workspaces: [(id: String, name: String)] {
        var names = Dictionary(model.page.items.compactMap { item -> (String, String)? in
            guard let id = item.workspace_id, let name = item.workspace_name else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        for workspace in workspaceOptions() { names[workspace.id] = workspace.name }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func count(for tab: ActivityViewModel.Tab) -> Int {
        switch tab {
        case .running: model.page.counts.running
        case .needsYou: model.page.counts.needs_you
        case .justFinished: model.page.counts.new_results
        case .finished: model.page.counts.finished
        }
    }
}

/// Text never carries state alone: every status pairs a symbol with its color.
private enum ActivityStatusStyle {
    static func symbol(_ state: String) -> String {
        switch state {
        case "running": "circle.dotted"
        case "queued": "clock"
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "interrupted": "exclamationmark.triangle.fill"
        case "stopped": "stop.circle"
        case "waiting_approval": "hand.raised.fill"
        case "waiting_answer": "questionmark.bubble.fill"
        default: "exclamationmark.bubble.fill"
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "running": DS.Palette.accent
        case "failed", "interrupted": DS.Palette.danger
        case "completed": DS.Palette.success
        case "stopped", "queued": DS.Palette.textSecondary
        default: DS.Palette.warning
        }
    }

    static func tone(_ state: String) -> DSPill.Tone {
        switch state {
        case "running": .accent
        case "failed", "interrupted": .danger
        case "completed": .success
        case "stopped", "queued": .neutral
        default: .warning
        }
    }
}

/// Resolves the Bot behind an Activity item: its own bot_id, else the Bot linked to its thread.
enum ActivityBotResolver {
    /// The item's own bot_id, else the Bot linked to its thread (in-memory cache only).
    static func botID(for item: ActivityWireItem, store: BotStore) -> BotID? {
        if let raw = item.bot_id, let uuid = UUID(uuidString: raw) { return BotID(uuid) }
        guard let raw = item.thread_id, let uuid = UUID(uuidString: raw) else { return nil }
        return store.cachedBotID(linkedTo: AgentThreadID(uuid))
    }
}

private struct ActivityRow: View {
    let item: ActivityWireItem
    var bot: BotDefinition? = nil
    let toggleRead: () -> Void
    let clear: () -> Void
    let open: (() -> Void)?
    let openLabel: String
    /// Off inside a workspace section, where the header already names the workspace.
    var showsWorkspace: Bool = true
    @State private var hovering = false
    @Environment(\.backgroundProminence) private var prominence

    /// Trailing slot shared by the age and the hover actions, so hovering never re-truncates the title.
    private static let trailingWidth: CGFloat = 58

    private var secondary: Color { prominence == .increased ? DS.Palette.text : DS.Palette.textSecondary }
    private var stateColor: Color { prominence == .increased ? DS.Palette.text : ActivityStatusStyle.color(item.state) }
    private var showsActions: Bool { hovering && (item.isMarkable || item.isClearable) }
    private var facts: String { factsLine(workspace: showsWorkspace) }
    private func factsLine(workspace: Bool) -> String {
        [workspace ? item.workspace_name : nil, item.provider, item.origin_label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Circle().fill(item.isUnread ? DS.Palette.accent : Color.clear)
                .frame(width: 7, height: 7).padding(.top, DS.Space.xs)
            if let bot {
                BotsAvatarView(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol.isEmpty ? nil : bot.avatarSymbol, size: 16,
                               attention: item.state == "running" ? .working : .none)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(bot.name)
                    .accessibilityIdentifier("activity.row.botAvatar.\(item.id)")
            } else {
                Image(systemName: ActivityStatusStyle.symbol(item.state))
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(stateColor).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                    Text(item.displayTitle).font(item.isUnread ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text).lineLimit(1)
                    Spacer(minLength: 0)
                    trailing
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                    Text(facts.isEmpty ? item.statusLabel : facts).font(DS.Font.caption)
                        .foregroundColor(facts.isEmpty ? stateColor : secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if !facts.isEmpty { Text(item.statusLabel).font(DS.Font.caption).foregroundColor(stateColor).lineLimit(1).layoutPriority(1) }
                }
                if let summary = item.listSummary {
                    Text(summary).font(DS.Font.caption).foregroundColor(secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, DS.Space.sm)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.displayTitle)
        .contextMenu {
            if let open { Button(openLabel, action: open) }
            if item.isMarkable { Button(item.isUnread ? "Mark as Read" : "Mark as Unread", action: toggleRead) }
            if item.isClearable { Button("Dismiss alert", action: clear) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.displayTitle, item.statusLabel, factsLine(workspace: true), item.listSummary ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(item.isUnread ? "Unread" : "")
        .accessibilityActions {
            if let open { Button(openLabel, action: open) }
            if item.isMarkable { Button(item.isUnread ? "Mark as read" : "Mark as unread", action: toggleRead) }
            if item.isClearable { Button("Dismiss alert", action: clear) }
        }
    }

    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if let date = item.occurredDate {
                Text(ActivityTimeLabel.compact(date)).font(DS.Font.caption).monospacedDigit()
                    .foregroundColor(secondary).opacity(showsActions ? 0 : 1)
                    .help(ActivityTimeLabel.full(date))
            }
            if showsActions {
                HStack(spacing: 0) {
                    if item.isMarkable {
                        DSIconButton(item.isUnread ? "envelope.open" : "envelope.badge", help: item.isUnread ? "Mark as read" : "Mark as unread", action: toggleRead).packed()
                    }
                    if item.isClearable {
                        DSIconButton("archivebox", help: "Dismiss alert", action: clear).packed()
                    }
                }
            }
        }.frame(width: Self.trailingWidth, height: 16, alignment: .trailing)
    }
}

private extension DSIconButton {
    /// Collapses the 44pt hit box to the glyph so a dense row keeps its height.
    func packed() -> some View {
        padding(.horizontal, -DSIconButton.visualPackInset)
            .padding(.vertical, -(DSIconButton.hitTargetSize - DSIconButton.visualSize.height) / 2)
    }
}

extension ActivityViewModel {
    var runningItems: [ActivityWireItem] { page.items.filter { $0.state != "queued" } }

    struct ItemSection: Identifiable { let id: String; let title: String; let items: [ActivityWireItem] }

    /// One list for every tab: rows grouped by workspace, in the order each workspace first
    /// appears (newest first). Items without a workspace go last.
    func workspaceSections(_ items: [ActivityWireItem]) -> [ItemSection] {
        var order: [String] = []
        var names: [String: String] = [:]
        var buckets: [String: [ActivityWireItem]] = [:]
        var unassigned: [ActivityWireItem] = []
        for item in items {
            guard let key = item.workspace_id, !key.isEmpty else { unassigned.append(item); continue }
            if buckets[key] == nil {
                order.append(key)
                names[key] = item.workspace_name.flatMap { $0.isEmpty ? nil : $0 } ?? "Workspace"
            }
            buckets[key, default: []].append(item)
        }
        var sections = order.map { ItemSection(id: $0, title: names[$0] ?? "Workspace", items: buckets[$0] ?? []) }
        if !unassigned.isEmpty { sections.append(ItemSection(id: "", title: "No workspace", items: unassigned)) }
        return sections
    }

    /// Sections as the list shows them. Needs you puts answers first inside each workspace.
    var listSections: [ItemSection] {
        let sections = workspaceSections(page.items)
        guard tab == .needsYou else { return sections }
        return sections.map { section in
            let ranked = section.items.enumerated().sorted { lhs, rhs in
                let left = Self.needsAnswerFirst(lhs.element) ? 0 : 1
                let right = Self.needsAnswerFirst(rhs.element) ? 0 : 1
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            return ItemSection(id: section.id, title: section.title, items: ranked.map(\.element))
        }
    }

    private static func needsAnswerFirst(_ item: ActivityWireItem) -> Bool {
        item.state == "waiting_approval" || item.state == "waiting_answer"
    }

    var queuedItems: [ActivityWireItem] { page.items.filter { $0.state == "queued" } }
    var cursorAvailable: Bool { cursor != nil }
    /// The host count covers the whole filter; the loaded rows cover a result the count cannot see yet.
    var hasUnreadResults: Bool { page.counts.new_results > 0 || page.items.contains(where: \.isUnread) }
    func dismissError() { error = nil }
}

/// Workspace group header shared by Activity and Schedule Tasks: folder in the
/// workspace color (tray for "No workspace"), name and item count.
struct WorkspaceSectionHeader: View {
    let title: String
    let count: Int?
    let hasWorkspace: Bool
    let color: Color?

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: hasWorkspace ? "folder.fill" : "tray")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(color ?? DS.Palette.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
            if let count { Text("\(count)").monospacedDigit().foregroundColor(DS.Palette.textTertiary) }
            Spacer(minLength: 0)
        }
        .font(DS.Font.caption.weight(.semibold)).foregroundColor(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
