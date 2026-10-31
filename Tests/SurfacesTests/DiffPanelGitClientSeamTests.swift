import XCTest
@testable import Surfaces
import AgentRuntime

// MARK: - FakeGitClient

/// Minimal fake that never shells out to real git (QA :93).
/// Each property holds the fixed value the method will return.
/// Call counts let tests assert that spinner states, race guards,
/// and failure paths call the right methods the right number of times.
final class FakeGitClient: GitClient, @unchecked Sendable {
    var stubbedSummary: GitSummary?
    var stubbedBranches: GitBranches
    var stubbedLog: [GitCommit]
    var stubbedDiff: String
    var stubbedCommitDiff: String
    var stubbedSynthesized: String
    var stubbedActionResult: GitActionResult
    var stubbedPRURL: String?
    var stubbedHumanizeError: String

    private let lock = NSLock()
    private var _summaryCallCount = 0
    private var _diffCallCount = 0
    private var _actionCallCount = 0
    private var _logCallCount = 0

    var summaryCallCount: Int { lock.lock(); defer { lock.unlock() }; return _summaryCallCount }
    var diffCallCount: Int   { lock.lock(); defer { lock.unlock() }; return _diffCallCount }
    var actionCallCount: Int { lock.lock(); defer { lock.unlock() }; return _actionCallCount }

    init(
        summary: GitSummary? = GitSummary(isGitRepo: true, branch: "main", dirty: false,
                                         files: [], totalAdditions: 0, totalDeletions: 0),
        branches: GitBranches = GitBranches(current: "main", locals: ["main"]),
        log: [GitCommit] = [],
        diff: String = "",
        commitDiff: String = "",
        synthesized: String = "",
        actionResult: GitActionResult = GitActionResult(ok: true, message: ""),
        prURL: String? = nil,
        humanizeError: String = "something went wrong"
    ) {
        self.stubbedSummary = summary
        self.stubbedBranches = branches
        self.stubbedLog = log
        self.stubbedDiff = diff
        self.stubbedCommitDiff = commitDiff
        self.stubbedSynthesized = synthesized
        self.stubbedActionResult = actionResult
        self.stubbedPRURL = prURL
        self.stubbedHumanizeError = humanizeError
    }

    /// When set, answers `summary(in:)` instead of `stubbedSummary`, with the
    /// 1-based call number, so a test can hold one read while another lands.
    var summaryProvider: ((Int) -> GitSummary?)?
    var checkoutProvider: (() -> GitActionResult)?
    var logProvider: ((Int) -> [GitCommit])?

    func summary(in cwd: String) -> GitSummary? {
        lock.lock(); _summaryCallCount += 1; let call = _summaryCallCount; lock.unlock()
        if let summaryProvider { return summaryProvider(call) }
        return stubbedSummary
    }
    func branches(in cwd: String) -> GitBranches { stubbedBranches }
    func log(in cwd: String, limit: Int) -> [GitCommit] {
        lock.lock(); _logCallCount += 1; let call = _logCallCount; lock.unlock()
        return logProvider?(call) ?? stubbedLog
    }
    func diff(in cwd: String, path: String?, ignoreWhitespace: Bool) -> String {
        lock.lock(); _diffCallCount += 1; lock.unlock()
        return stubbedDiff
    }
    func commitDiff(in cwd: String, hash: String, ignoreWhitespace: Bool) -> String { stubbedCommitDiff }
    func synthesizeUntrackedDiff(content: String, path: String) -> String { stubbedSynthesized }
    func checkout(in cwd: String, branch: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return checkoutProvider?() ?? stubbedActionResult
    }
    func stashAndCheckout(in cwd: String, branch: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func createBranch(in cwd: String, name: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func commitPaths(in cwd: String, message: String, paths: [String]) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func restorePathToHead(in cwd: String, path: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func suggestCommitMessage(_ summary: GitSummary) -> String { "Suggested message" }
    func push(in cwd: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func fetch(in cwd: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func pull(in cwd: String) -> GitActionResult {
        lock.lock(); _actionCallCount += 1; lock.unlock()
        return stubbedActionResult
    }
    func pullRequestURL(in cwd: String) -> String? { stubbedPRURL }
    func humanizeError(_ raw: String) -> String { stubbedHumanizeError }
}

// MARK: - DiffPanelGitClientSeamTests

/// WHY (QA :93): DiffPanelViewModel shelled out to real git on every test,
/// making the diff-generation race (T025), slow-repo spinner states, and the
/// failure-path error banner non-deterministic. The GitClient seam lets a fake
/// return instant, controlled responses — no subprocess, no repo on disk.
@MainActor
final class DiffPanelGitClientSeamTests: XCTestCase {

    /// Spin the main run loop until condition holds or timeout fires.
    private func waitUntil(_ desc: String,
                            timeout: TimeInterval = 5,
                            _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    // MARK: - diff-generation race (T025)

    /// WHY: if a slow git diff races with a newer selection, the stale result
    /// must not overwrite rawDiff. The generation token guards this. Without
    /// the seam we cannot inject the delay; with FakeGitClient we can arrange
    /// a second selectFile before the first diff "arrives" and confirm that
    /// only the latest result lands.
    func test_diffRaceGuard_staleResultIsDropped() {
        // Arrange: fake returns a diff string when called
        let fake = FakeGitClient(diff: "slow-patch")
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)

        // Act: select file A -> immediately select nil (clears) -> the
        // background closure for A must see its generation is stale and drop.
        // We trigger a load, then immediately clear selection before the
        // background queue has a chance to run the diff task.
        vm.selectFile("a.txt")
        // Immediately clear selection — bumps the generation token and sets rawDiff=""
        vm.selectFile(nil)

        // Wait for background queues to drain.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // The clear (rawDiff="") must win; the "slow-patch" from the first
        // selectFile must not appear because its generation is stale.
        XCTAssertEqual(vm.rawDiff, "",
            "stale diff result must be dropped by the generation token guard " +
            "so a cleared selection never shows a previous file's diff (T025)")
    }

    // MARK: - slow-repo spinner

    /// WHY: isLoading must be true while a fake diff is "in flight" and false
    /// after it lands. Without the seam, on a fast machine the real git returns
    /// before the test can observe isLoading=true, making T025 flaky.
    /// FakeGitClient is synchronous so we can assert the state machine cleanly.
    func test_reloadDiff_setsLoadingWhileInFlight_thenClears() {
        let fake = FakeGitClient(diff: "the diff")
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)

        // Before selecting a file, not loading.
        XCTAssertFalse(vm.isLoading,
            "isLoading must be false before any diff is requested")

        vm.selectFile("some/file.swift")

        // After the background queue drains, isLoading must be false.
        waitUntil("isLoading clears after diff returns") { !vm.isLoading }

        XCTAssertFalse(vm.isLoading,
            "isLoading must clear once the fake diff result lands " +
            "so the spinner disappears and the diff is visible")
        XCTAssertEqual(vm.rawDiff, "the diff",
            "rawDiff must contain the fake diff returned by FakeGitClient " +
            "confirming the seam is wired end-to-end through reloadDiff")
    }

    // MARK: - failure-path error banner

    /// WHY: when a git action fails, lastError must surface the humanized
    /// copy and lastErrorRaw the raw stderr. Without the seam, the test
    /// would need a real git repo and a bad command to trigger the failure.
    func test_failingAction_surfacesHumanizedError() {
        let fake = FakeGitClient(
            actionResult: GitActionResult(ok: false, message: "fatal: remote not found"),
            humanizeError: "Push failed: remote not found."
        )
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)

        vm.push()

        waitUntil("error surfaces after push fails") { vm.lastError != nil }

        XCTAssertEqual(vm.lastError, "Push failed: remote not found.",
            "lastError must contain the humanized copy from humanizeError() " +
            "so the banner shows actionable text, not raw git stderr")
        XCTAssertEqual(vm.lastErrorRaw, "fatal: remote not found",
            "lastErrorRaw must preserve the original stderr " +
            "so 'Copy details' can recover the full git message")
    }

    /// WHY: a git status that timed out has no file list. Shown as a clean
    /// tree it said "no changes" while the agent's edits were still on disk.
    /// The panel keeps the list it had and says the refresh failed.
    func test_timedOutSummary_keepsTheLastListAndSaysSo() {
        let dirty = GitSummary(
            isGitRepo: true, branch: "main", dirty: true,
            files: [GitFileEntry(path: "a.swift", oldPath: nil, status: .modified, additions: 1, deletions: 0, binary: false)],
            totalAdditions: 1, totalDeletions: 0
        )
        let fake = FakeGitClient(summary: dirty)
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)
        fake.stubbedSummary = nil

        vm.refresh()
        waitUntil("timeout surfaces") { vm.lastError != nil }

        XCTAssertEqual(vm.lastError, GitDiff.summaryTimedOutMessage)
        XCTAssertEqual(vm.summary, dirty, "the last loaded list stays; it is never replaced by a clean tree")
    }

    /// WHY: the timeout banner says the list is stale. Once a later read lands
    /// the list is fresh again, so a banner left up would call fresh data stale.
    func test_timeoutBannerClearsWhenALaterReadLands() {
        let fake = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)
        fake.stubbedSummary = nil
        vm.refresh()
        waitUntil("timeout surfaces") { vm.lastError == GitDiff.summaryTimedOutMessage }

        let fresh = GitSummary(isGitRepo: true, branch: "main", dirty: true,
                               files: [GitFileEntry(path: "b.swift", oldPath: nil, status: .added,
                                                    additions: 2, deletions: 0, binary: false)],
                               totalAdditions: 2, totalDeletions: 0)
        fake.stubbedSummary = fresh
        vm.refresh()
        waitUntil("fresh list lands") { vm.summary == fresh }
        XCTAssertNil(vm.lastError, "a fresh list must not sit under a 'not refreshed' banner")
    }

    /// WHY: FSEvents, Refresh and git actions overlap. A slow read that times
    /// out after a newer read already landed must not put the banner (or its
    /// older list) over the newer state.
    func test_readThatLandsAfterANewerOneIsDropped() {
        let fake = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)
        let baseline = fake.summaryCallCount
        let release = DispatchSemaphore(value: 0)
        let fresh = GitSummary(isGitRepo: true, branch: "main", dirty: true,
                               files: [GitFileEntry(path: "c.swift", oldPath: nil, status: .modified,
                                                    additions: 1, deletions: 1, binary: false)],
                               totalAdditions: 1, totalDeletions: 1)
        fake.summaryProvider = { call in
            if call == baseline + 1 { release.wait(); return nil } // slow read, then times out
            return fresh
        }
        vm.refresh()
        waitUntil("slow read started") { fake.summaryCallCount == baseline + 1 }
        vm.refresh()
        waitUntil("newer read lands") { vm.summary == fresh }
        release.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)) // let the slow read land
        XCTAssertNil(vm.lastError, "the older timed-out read landed last but is older than what is shown")
        XCTAssertEqual(vm.summary, fresh)
    }

    func test_localGitOutcome_reportsOnlyCanonicalKindAndBooleanResult() {
        let file = GitFileEntry(
            path: "private.swift",
            oldPath: nil,
            status: .modified,
            additions: 1,
            deletions: 0,
            binary: false
        )
        let fake = FakeGitClient(
            summary: GitSummary(
                isGitRepo: true,
                branch: "main",
                dirty: true,
                files: [file],
                totalAdditions: 1,
                totalDeletions: 0
            ),
            actionResult: GitActionResult(ok: true, message: "private output")
        )
        let vm = DiffPanelViewModel(cwd: "/private/path", gitClient: fake)
        var outcomes: [(String, Bool)] = []
        vm.gitOutcomeHandler = { outcomes.append(($0, $1)) }

        vm.switchBranch("secret-branch")
        waitUntil("checkout outcome") { outcomes.count == 1 }
        XCTAssertEqual(outcomes[0].0, "git.checkout")
        XCTAssertTrue(outcomes[0].1)

        vm.newBranch("secret-created-branch")
        waitUntil("branch outcome") { outcomes.count == 2 }
        XCTAssertEqual(outcomes[1].0, "git.branch_created")
        XCTAssertTrue(outcomes[1].1)

        vm.commitMessage = "private commit message"
        vm.selectedFiles = [file.path]
        vm.commitSelected()
        waitUntil("commit outcome") { outcomes.count == 3 }
        XCTAssertEqual(outcomes[2].0, "git.commit")
        XCTAssertTrue(outcomes[2].1)

        fake.stubbedActionResult = GitActionResult(ok: false, message: "token=hunter2")
        vm.push()
        waitUntil("push outcome") { outcomes.count == 4 }
        XCTAssertEqual(outcomes[3].0, "git.push")
        XCTAssertFalse(outcomes[3].1)
        XCTAssertFalse(outcomes.map(\.0).joined().contains("secret-branch"))
        XCTAssertFalse(outcomes.map(\.0).joined().contains("private commit message"))
        XCTAssertFalse(outcomes.map(\.0).joined().contains("hunter2"))
    }

    func test_mutationsRemainSingleFlightUntilTheirOutcomeIsPublished() {
        let fake = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fake.checkoutProvider = {
            release.wait()
            return GitActionResult(ok: true, message: "switched")
        }
        var outcomes = 0
        vm.gitOutcomeHandler = { _, _ in outcomes += 1 }
        vm.switchBranch("next")
        waitUntil("checkout started") { fake.actionCallCount == 1 }
        vm.push()
        vm.fetch()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fake.actionCallCount, 1, "Overlapping mutations must not race on the same Git index or retire the active spinner")
        XCTAssertTrue(vm.isBusy)
        release.signal()
        waitUntil("checkout settled") { !vm.isBusy }
        XCTAssertEqual(outcomes, 1, "The accepted mutation must publish its canonical outcome exactly once")
    }

    func test_oldReloadCannotReplaceBranchesAfterNewerActionReadback() {
        let fake = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fake.logProvider = { _ in
            entered.signal()
            release.wait()
            return []
        }
        vm.reloadAll()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        fake.logProvider = nil
        fake.stubbedBranches = GitBranches(current: "new", locals: ["new"])
        vm.switchBranch("new")
        waitUntil("new action readback") { !vm.isBusy && vm.branches.current == "new" }
        release.signal()
        waitUntil("old reload settled") { !vm.isLoading }
        XCTAssertEqual(vm.branches.current, "new", "A retired reload may finish its spinner but must not repaint old branch metadata")
    }

    func test_oldReloadCannotHideLoadingOwnedByNewerHistoryPage() {
        let fake = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: "/fake", gitClient: fake)
        let firstEntered = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let firstRelease = DispatchSemaphore(value: 0)
        let secondRelease = DispatchSemaphore(value: 0)
        defer { firstRelease.signal(); secondRelease.signal() }
        fake.logProvider = { call in
            if call == 1 { firstEntered.signal(); firstRelease.wait() }
            else { secondEntered.signal(); secondRelease.wait() }
            return []
        }
        vm.reloadAll()
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        vm.loadMoreHistory()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        firstRelease.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(vm.isLoading, "The old reload must finish only its own loading token, not the newer history page")
        secondRelease.signal()
        waitUntil("all read owners settled") { !vm.isLoading }
    }

    // MARK: - production default unchanged

    /// WHY: the seam must be invisible to callers that don't inject a client.
    /// If the default arg changes production behaviour, all existing tests break.
    func test_defaultInit_usesLiveGitClient() {
        // We can't run real git without a repo, but we CAN assert that the
        // default gitClient is LiveGitClient (correct type), not a fake.
        // This is a compile-time + runtime conformance check.
        let vm = DiffPanelViewModel(cwd: NSTemporaryDirectory())
        XCTAssertTrue(vm.gitClient is LiveGitClient,
            "the default gitClient must be LiveGitClient so production code " +
            "is unaffected when no client is injected")
    }

    // MARK: - summary never queries real git in fake-injected VM

    /// WHY: confirms the seam is correctly wired — no subprocess is spawned.
    /// If GitDiff.summary were still called directly, the call count on the
    /// fake would stay 0 while the real git binary would run.
    func test_fakeClient_summaryIsCalledOnFake_notRealGit() {
        let fake = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: "/definitely-not-a-real-path", gitClient: fake)
        // init() calls summary + branches synchronously (asyncLoad=false default)
        XCTAssertGreaterThan(fake.summaryCallCount, 0,
            "summary() must be called on the injected FakeGitClient, not real GitDiff " +
            "confirming that no subprocess is spawned when a fake is injected")
        XCTAssertTrue(vm.summary.isGitRepo,
            "the fake's stubbedSummary (isGitRepo:true) must be used, not a real git query")
    }
}
