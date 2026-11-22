import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Stream events reach the Agent App transcript through one serial chain:
/// a flush reduces a quantum off the main actor, and only that quantum's
/// finish frees the latch and flushes what arrived meanwhile. A thread open
/// bumps the generation and drops the quantum still in flight. These tests
/// land that stale finish late, as the production detached reduce can, and
/// check the chain keeps painting the thread the user opened.
@MainActor
final class AgentAppStreamQuantumGenerationTests: XCTestCase {

    private var finishes: [() -> Void] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
        finishes = []
    }

    private func makeVM() throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-stream-quantum-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo
        )
        return (vm, threadRepo)
    }

    private func makeThread(_ vm: AgentAppViewModel, _ repo: AgentThreadRepository, title: String) throws -> AgentThread {
        let thread = AgentThread(
            workspaceId: vm.workspaceID, title: title, provider: .codex, model: "gpt-5.5", status: .completed
        )
        try repo.upsert(thread)
        return thread
    }

    private func open(_ vm: AgentAppViewModel, _ thread: AgentThread) async {
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
    }

    private func pump(_ vm: AgentAppViewModel, _ thread: AgentThread, turnId: String) {
        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: turnId), run: AgentRunID(), threadId: thread.id)
    }

    /// Lets the flush Tasks scheduled by `pump` run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Lands every captured finish, oldest first, until the chain is idle.
    private func landAll() async {
        var idleRounds = 0
        // A committed quantum schedules the next flush after a 4 ms gap.
        while idleRounds < 20 {
            if finishes.isEmpty {
                idleRounds += 1
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }
            idleRounds = 0
            finishes.removeFirst()()
            await Task.yield()
        }
    }

    func test_staleFinishAfterThreadSwitch_keepsPaintingTheOpenedThread() async throws {
        // WHY: events that arrive while a quantum is in flight have only that
        // quantum's finish as their flush. If a thread switch drops it and the
        // dropped finish does not re-drive them, the batch stays marked
        // "flush scheduled" and every later event of the opened thread is only
        // buffered: its live run stops painting.
        let (vm, repo) = try makeVM()
        defer { vm.dispose() }
        let previous = try makeThread(vm, repo, title: "previous")
        let opened = try makeThread(vm, repo, title: "opened")
        await open(vm, previous)
        vm.streamQuantumFinishForTesting = { [unowned self] finish in finishes.append(finish) }

        pump(vm, previous, turnId: "in-flight")
        await settle()
        XCTAssertEqual(finishes.count, 1, "precondition: one quantum in flight")
        pump(vm, previous, turnId: "buffered-behind-it")
        await settle()
        XCTAssertEqual(finishes.count, 1, "precondition: the second event waits behind the in-flight quantum")

        await open(vm, opened)
        let stale = finishes.removeFirst()
        stale()
        await settle()

        pump(vm, opened, turnId: "opened-live")
        await settle()
        await landAll()

        XCTAssertEqual(
            vm.timeline.turns.map(\.turnId), ["opened-live"],
            "the opened thread's live event must reach its transcript after a dropped quantum"
        )
    }

    func test_staleFinish_doesNotReleaseTheLatchOfANewerQuantum() async throws {
        // WHY: the latch keeps quanta serial. A dropped quantum that frees the
        // latch of the newer one lets a third quantum reduce from the timeline
        // without the second's events; whichever commits last wins, so the
        // other quantum's events vanish from the transcript.
        let (vm, repo) = try makeVM()
        defer { vm.dispose() }
        let previous = try makeThread(vm, repo, title: "previous")
        let opened = try makeThread(vm, repo, title: "opened")
        await open(vm, previous)
        vm.streamQuantumFinishForTesting = { [unowned self] finish in finishes.append(finish) }

        pump(vm, previous, turnId: "in-flight")
        await settle()
        XCTAssertEqual(finishes.count, 1, "precondition: one quantum in flight")

        await open(vm, opened)
        pump(vm, opened, turnId: "second")
        await settle()
        XCTAssertEqual(finishes.count, 2, "precondition: the opened thread's quantum is in flight beside the stale one")

        let stale = finishes.removeFirst()
        stale()
        pump(vm, opened, turnId: "third")
        await settle()
        XCTAssertEqual(finishes.count, 1, "no quantum may start while the newer one is still in flight")

        await landAll()
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), ["second", "third"])
    }

    func test_leavingThreadsQuantum_landingBeforeTheOpen_staysOutOfTheOpenedThread() async throws {
        // WHY: a quantum is reduced from the thread that was selected when it
        // started. If it lands after the user picked another thread but before
        // that thread's open bumps the generation (one main-queue hop later),
        // it replaces the opened thread's timeline with the previous thread's,
        // and the open then keeps those turns as "painted during the open":
        // the opened thread shows another thread's transcript.
        let (vm, repo) = try makeVM()
        defer { vm.dispose() }
        let previous = try makeThread(vm, repo, title: "previous")
        let opened = try makeThread(vm, repo, title: "opened")
        await open(vm, previous)
        vm.streamQuantumFinishForTesting = { [unowned self] finish in finishes.append(finish) }

        pump(vm, previous, turnId: "previous-live")
        await settle()
        XCTAssertEqual(finishes.count, 1, "precondition: the previous thread's quantum is in flight")

        vm.selectThread(opened.id)
        finishes.removeFirst()()
        await vm.waitForSelectThreadHydrationForTesting()
        await landAll()

        XCTAssertEqual(vm.selectedThreadId, opened.id)
        XCTAssertEqual(
            vm.timeline.turns.map(\.turnId), [],
            "the opened thread must not show the previous thread's turns"
        )
    }
}
