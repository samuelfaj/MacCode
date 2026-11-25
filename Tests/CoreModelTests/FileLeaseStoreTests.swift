import XCTest
@testable import CoreModel

final class FileLeaseStoreTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }

    private func holder(_ run: AgentRunID, title: String = "Refactor", bot: String? = nil, since: Date = Date()) -> FileLeaseHolder {
        FileLeaseHolder(runID: run, threadID: AgentThreadID(), threadTitle: title, botLabel: bot, since: since)
    }

    func test_aSecondRunNeverTakesALiveLease() {
        let clock = Clock()
        let store = FileLeaseStore(now: { clock.now })
        let first = AgentRunID(), second = AgentRunID()
        XCTAssertEqual(store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(first)), .granted)
        guard case .heldByOther(let owner) = store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(second)) else {
            return XCTFail("a live lease must be reported, not replaced")
        }
        XCTAssertEqual(owner.runID, first)
        XCTAssertEqual(store.conflict(repoRoot: "/r", path: "a.swift", runID: second)?.runID, first)
        XCTAssertNil(store.conflict(repoRoot: "/r", path: "a.swift", runID: first), "the holder never conflicts with itself")
    }

    func test_leasesAreScopedPerCheckoutAndPath() {
        let store = FileLeaseStore()
        let first = AgentRunID(), second = AgentRunID()
        store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(first))
        XCTAssertNil(store.conflict(repoRoot: "/r", path: "b.swift", runID: second))
        XCTAssertNil(store.conflict(repoRoot: "/worktree", path: "a.swift", runID: second),
                     "a worktree is its own checkout: the same relative path is a different file")
    }

    func test_aLeaseExpiresAfterTenMinutesAndEachEditRenewsIt() {
        let clock = Clock()
        let store = FileLeaseStore(now: { clock.now })
        let first = AgentRunID(), second = AgentRunID()
        store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(first))
        clock.advance(9 * 60)
        XCTAssertNotNil(store.conflict(repoRoot: "/r", path: "a.swift", runID: second))
        store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(first))
        clock.advance(9 * 60)
        XCTAssertNotNil(store.conflict(repoRoot: "/r", path: "a.swift", runID: second), "the edit at minute 9 renewed the lease")
        clock.advance(2 * 60)
        XCTAssertNil(store.conflict(repoRoot: "/r", path: "a.swift", runID: second), "a lease nobody renews frees itself after the TTL")
        XCTAssertEqual(store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(second)), .granted)
        XCTAssertEqual(FileLeaseStore.ttl, 600)
    }

    func test_renewalKeepsTheOriginalStartForTheConflictMessage() {
        let clock = Clock()
        let store = FileLeaseStore(now: { clock.now })
        let run = AgentRunID()
        store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(run))
        let started = clock.now
        clock.advance(3 * 60)
        store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(run))
        XCTAssertEqual(store.conflict(repoRoot: "/r", path: "a.swift", runID: AgentRunID())?.since, started)
    }

    func test_releasingARunFreesEveryFileItHeld() {
        let store = FileLeaseStore()
        let first = AgentRunID(), second = AgentRunID()
        store.acquire(repoRoot: "/r", path: "a.swift", holder: holder(first))
        store.acquire(repoRoot: "/r", path: "b.swift", holder: holder(first))
        store.acquire(repoRoot: "/r", path: "c.swift", holder: holder(second))
        XCTAssertEqual(store.release(runID: first), 2)
        XCTAssertEqual(store.release(runID: first), 0)
        XCTAssertEqual(store.activeLeases().map(\.path), ["c.swift"], "the other run keeps its lease")
    }

    func test_conflictMessageNamesFileThreadBotAndMinutes() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let holder = holder(AgentRunID(), title: "Fix login", bot: "@qa", since: now.addingTimeInterval(-3 * 60 - 20))
        XCTAssertEqual(
            FileLeaseMessage.conflict(path: "Sources/Login.swift", holder: holder, now: now),
            "`Sources/Login.swift` is being edited by thread 'Fix login' (Bot @qa) for 3 min. Edit another file, wait, or use a worktree."
        )
        let plain = self.holder(AgentRunID(), title: "Fix login", since: now)
        XCTAssertTrue(FileLeaseMessage.conflict(path: "a", holder: plain, now: now).contains("thread 'Fix login' for under 1 min."))
    }

    func test_snapshotFindsHoldersByRepoRelativeOrDirectoryRelativePath() {
        let run = ConcurrentRunSummary(
            runID: AgentRunID(), threadID: AgentThreadID(), threadTitle: "Other", botID: nil, botName: "Qa",
            objective: "x", branch: "main", worktreePath: "/r",
            editingFiles: [ConcurrentRunFile(path: "pkg/a.swift", since: Date())], startedAt: Date()
        )
        let snapshot = ConcurrentWorkSnapshot(runs: [run], cwdPrefix: "pkg/")
        XCTAssertEqual(snapshot.holders(of: "pkg/a.swift").count, 1, "git lists tracked files from the repo root")
        XCTAssertEqual(snapshot.holders(of: "a.swift").count, 1, "and untracked files from the surface directory")
        XCTAssertTrue(snapshot.holders(of: "b.swift").isEmpty)
        XCTAssertEqual(snapshot.label(for: run), "Other · Qa")
    }

    func test_policiesDecodeFromTheirStoredNames() {
        XCTAssertEqual(FileLeaseMode(rawValue: "block"), .block)
        XCTAssertEqual(LocalRunConflictPolicy(rawValue: "autoWorktree"), .autoWorktree)
        XCTAssertNil(LocalRunConflictPolicy(rawValue: "AUTO_WORKTREE"))
    }
}
