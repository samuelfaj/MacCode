import XCTest
@testable import SocketServer

/// In-memory stand-in for the settings row the ledger persists.
private final class RevisionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var failing = false

    func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func save(_ next: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw RevisionStoreFailure() }
        value = next
    }

    func failWrites() {
        lock.lock(); failing = true; lock.unlock()
    }
}

private struct RevisionStoreFailure: Error {}

private let allDomains: Set<String> = ["shell", "surfaces", "agentThreads", "browser", "files"]

private func snapshotState(
    workspaceName: String = "Main",
    threadTitle: String = "Thread"
) -> ConnectionSnapshotReadState {
    ConnectionSnapshotReadState(
        selectedWorkspaceId: "w-1",
        workspaces: [.object(["id": .string("w-1"), "name": .string(workspaceName)])],
        surfaces: [ConnectionSnapshotWorkspaceItems(
            workspaceId: "w-1",
            items: [.object(["id": .string("s-1"), "type": .string("browser")])]
        )],
        agentThreads: [ConnectionSnapshotWorkspaceItems(
            workspaceId: "w-1",
            items: [.object(["id": .string("t-1"), "workspaceId": .string("w-1"), "title": .string(threadTitle)])]
        )],
        browserStates: [ConnectionSnapshotSurfaceState(
            workspaceId: "w-1", surfaceId: "s-1", state: .object(["url": .string("https://example.test")])
        )],
        filesStates: [ConnectionSnapshotSurfaceState(
            workspaceId: "w-1", surfaceId: "s-2", state: .object(["selected_path": .null])
        )]
    )
}

/// V1/V3: why it matters. A Mac restart used to make every iPhone download the
/// whole snapshot, because EventBus revisions are event seqs that a new boot
/// rebuilds from the event log (lower, and reusable after a crash). The
/// ledger must keep a revision across a restart only when the domain provably
/// did not change, and otherwise hand out a value above anything served before,
/// so a client's `knownDomainRevisions` from the old boot never hides a change.
final class DurableDomainRevisionsTests: XCTestCase {
    private func makeLedger(
        _ store: RevisionStore,
        boot: UInt64,
        bus: EventBus,
        previousBootClean: Bool
    ) throws -> ConnectionDurableDomainRevisions {
        try ConnectionDurableDomainRevisions(
            bootEpoch: boot,
            bootFloor: bus.currentSeq,
            previousBootClean: previousBootClean,
            load: { store.load() },
            save: { try store.save($0) }
        )
    }

    private func publishOnEveryDomain(_ bus: EventBus) {
        for kind in ["workspace.updated", "surface.updated", "agent.thread.updated",
                     "browser.updated", "files.updated"] {
            bus.publishRawForTesting(kind: kind, payload: .object([:]))
        }
    }

    /// A boot that publishes on every domain and serves one snapshot.
    private func oldBoot(
        _ store: RevisionStore,
        state: ConnectionSnapshotReadState = snapshotState()
    ) throws -> (bus: EventBus, ledger: ConnectionDurableDomainRevisions, known: ConnectionDomainRevisions) {
        let bus = EventBus()
        let ledger = try makeLedger(store, boot: 41, bus: bus, previousBootClean: false)
        publishOnEveryDomain(bus)
        let known = try ledger.resolve(bus: bus.snapshotMetadata().domainRevisions, state: state)
        return (bus, ledger, known)
    }

    /// The next boot as AppDelegate builds it: the bus starts at the event-log
    /// head, the ledger installs, then the deferred reload rebuilds EventBus
    /// revisions from the oldest logged events (lower than the old boot's).
    /// `logHead` is the last logged seq; live-only events after it are lost.
    private func newBoot(
        _ store: RevisionStore,
        after old: EventBus,
        logHead: Int64? = nil,
        previousBootClean: Bool
    ) throws -> (bus: EventBus, ledger: ConnectionDurableDomainRevisions) {
        let head = logHead ?? old.currentSeq
        let bus = EventBus()
        bus.reloadFromPersistence(lastSeq: head, recent: [])
        let ledger = try makeLedger(store, boot: 42, bus: bus, previousBootClean: previousBootClean)
        bus.reloadFromPersistence(lastSeq: head, recent: [
            EventBus.Event(seq: 1, kind: "workspace.updated", payload: .object([:]), ts: 0),
            EventBus.Event(seq: 2, kind: "surface.updated", payload: .object([:]), ts: 0),
        ])
        return (bus, ledger)
    }

    func test_cleanRestart_unchangedDomainsKeepTheirRevisions_soTheClientGetsAnEmptyPartial() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        old.ledger.seal(bus: old.bus.snapshotMetadata().domainRevisions)

        let next = try newBoot(store, after: old.bus, previousBootClean: true)
        let served = try next.ledger.resolve(bus: next.bus.snapshotMetadata().domainRevisions, state: snapshotState())

        XCTAssertEqual(served, old.known,
                       "a restart that changed nothing must neither lower nor bump any revision")
        XCTAssertEqual(served.domainsChanged(since: old.known), [])
        let wire = snapshotState().jsonValue(domainRevisions: served, includeDomains: served.domainsChanged(since: old.known))
        XCTAssertEqual(wire.objectValue?["partial"], .bool(true))
        XCTAssertEqual(wire.objectValue?["includedDomains"], .array([]))
        XCTAssertNil(wire.objectValue?["workspaces"], "no domain content is resent")
    }

    /// The old boot ended with terminal output, which is never logged, so the
    /// new boot reuses those seqs. A surface change after the restart then has
    /// a lower seq than the revision the client holds and must still count.
    func test_cleanRestart_eventAfterBoot_includesOnlyThatDomain_evenWhenItsSeqIsReused() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        let logHead = old.bus.currentSeq
        for _ in 0..<3 {
            old.bus.publishRawForTesting(kind: "surface.output", payload: .object([:]))
        }
        let known = try old.ledger.resolve(bus: old.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        old.ledger.seal(bus: old.bus.snapshotMetadata().domainRevisions)

        let next = try newBoot(store, after: old.bus, logHead: logHead, previousBootClean: true)
        next.bus.publishRawForTesting(kind: "surface.updated", payload: .object([:]))
        let served = try next.ledger.resolve(bus: next.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(served.domainsChanged(since: known), ["surfaces"])
    }

    /// A restart can change content without any event (in-memory state such
    /// as pending Mac executions is gone). The content digest catches it.
    func test_cleanRestart_silentContentChange_includesThatDomain() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        old.ledger.seal(bus: old.bus.snapshotMetadata().domainRevisions)

        let next = try newBoot(store, after: old.bus, previousBootClean: true)
        let served = try next.ledger.resolve(
            bus: next.bus.snapshotMetadata().domainRevisions,
            state: snapshotState(workspaceName: "Restored differently")
        )
        XCTAssertEqual(served.domainsChanged(since: old.known), ["shell"])
    }

    /// A domain that changed after its revision was served (and changed back)
    /// may differ on the client, which applied only part of it live. Equal
    /// content alone must not keep the revision.
    func test_changeAfterLastServe_isNotSealed_evenIfContentEndsTheSame() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        old.bus.publishRawForTesting(kind: "agent.thread.updated", payload: .object([:]))
        old.bus.publishRawForTesting(kind: "agent.thread.updated", payload: .object([:]))
        old.ledger.seal(bus: old.bus.snapshotMetadata().domainRevisions)

        let next = try newBoot(store, after: old.bus, previousBootClean: true)
        let served = try next.ledger.resolve(bus: next.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(served.domainsChanged(since: old.known), ["agentThreads"])
    }

    func test_crash_noSeal_resendsEveryDomain_aboveEverythingServedBefore() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        // Serve past the first reserved block so the crash happens mid-block.
        var highest = old.known
        for _ in 0..<(ConnectionDurableDomainRevisions.reservationBlock + 10) {
            old.bus.publishRawForTesting(kind: "workspace.updated", payload: .object([:]))
            highest = try old.ledger.resolve(bus: old.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        }

        let next = try newBoot(store, after: old.bus, previousBootClean: true)
        let served = try next.ledger.resolve(bus: next.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(served.domainsChanged(since: highest), allDomains,
                       "after a crash nothing is proven unchanged")
        let maxServedBefore = ConnectionDomainRevisions.domainNames.map { highest.revision(of: $0) }.max()!
        for domain in ConnectionDomainRevisions.domainNames {
            XCTAssertGreaterThan(served.revision(of: domain), maxServedBefore,
                                 "\(domain) must never reuse a revision a client may hold")
        }
    }

    /// C8 invalidates its record when an event lands after the quit sealed;
    /// AppDelegate then passes previousBootClean = false.
    func test_previousQuitNotClean_keepsNothing() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        old.ledger.seal(bus: old.bus.snapshotMetadata().domainRevisions)

        let next = try newBoot(store, after: old.bus, previousBootClean: false)
        let served = try next.ledger.resolve(bus: next.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(served.domainsChanged(since: old.known), allDomains)
    }

    func test_withinOneBoot_revisionMovesOnlyWithItsDomain_andNeverBackward() throws {
        let store = RevisionStore()
        let old = try oldBoot(store)
        let again = try old.ledger.resolve(bus: old.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(again, old.known)

        old.bus.publishRawForTesting(kind: "agent.item.delta", payload: .object([:]))
        old.bus.publishRawForTesting(kind: "surface.updated", payload: .object([:]))
        let after = try old.ledger.resolve(bus: old.bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(after.domainsChanged(since: old.known), ["surfaces"])
        for domain in ConnectionDomainRevisions.domainNames {
            XCTAssertGreaterThanOrEqual(after.revision(of: domain), old.known.revision(of: domain))
        }
    }

    /// Builds before the ledger served seq-valued revisions. The first durable
    /// values must sit above them, or a client holding one would read "unchanged".
    func test_firstUse_startsAboveLegacySeqRevisions() throws {
        let store = RevisionStore()
        let bus = EventBus()
        bus.reloadFromPersistence(lastSeq: 5_000, recent: [])
        let ledger = try makeLedger(store, boot: 9, bus: bus, previousBootClean: true)
        let legacyKnown = ConnectionDomainRevisions(
            shell: 5_000, surfaces: 900_000, agentThreads: 4_999, browser: 12, files: 7
        )
        let served = try ledger.resolve(bus: bus.snapshotMetadata().domainRevisions, state: snapshotState())
        XCTAssertEqual(served.domainsChanged(since: legacyKnown), allDomains)
    }

    func test_counterBlockThatCannotBePersisted_failsInsteadOfServing() throws {
        let store = RevisionStore()
        let bus = EventBus()
        let ledger = try makeLedger(store, boot: 3, bus: bus, previousBootClean: false)
        store.failWrites()
        // Five mints on the first read, then one per read up to the block end.
        _ = try ledger.resolve(bus: bus.snapshotMetadata().domainRevisions, state: snapshotState())
        for _ in 0..<(ConnectionDurableDomainRevisions.reservationBlock - 5) {
            bus.publishRawForTesting(kind: "workspace.updated", payload: .object([:]))
            _ = try ledger.resolve(bus: bus.snapshotMetadata().domainRevisions, state: snapshotState())
        }
        bus.publishRawForTesting(kind: "workspace.updated", payload: .object([:]))
        XCTAssertThrowsError(
            try ledger.resolve(bus: bus.snapshotMetadata().domainRevisions, state: snapshotState()),
            "a revision above the persisted ceiling could be reused after a crash"
        )
    }

    func test_bootRecordThatCannotBePersisted_disablesTheLedger() {
        let store = RevisionStore()
        store.failWrites()
        XCTAssertThrowsError(try makeLedger(store, boot: 1, bus: EventBus(), previousBootClean: false))
    }
}
