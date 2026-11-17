import XCTest
@testable import AppShell
@testable import SocketServer
@testable import Persistence
import CoreModel

/// V1 across a real restart: the real settings table, the real event log and
/// the real C8 clean-quit record, in AppDelegate's order (restore C8, install
/// the ledger; on quit write C8, then seal). Why it matters: a Mac restart may
/// keep a domain revision an iPhone already holds only when the previous quit
/// was provably clean; after a crash or a late event every domain is resent.
@MainActor
final class DurableDomainRevisionsRestartTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "RC2DurableRevisions-" + UUID().uuidString
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private let state = ConnectionSnapshotReadState(
        selectedWorkspaceId: "w-1",
        workspaces: [.object(["id": .string("w-1"), "name": .string("Main")])],
        surfaces: [],
        agentThreads: [],
        browserStates: [],
        filesStates: []
    )

    private func boot() throws -> (AppContext, EventBus, ConnectionDurableDomainRevisions) {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let bus = EventBus()
        AppDelegate.wireEventPersistence(context: context, eventBus: bus)
        bus.reloadFromPersistence(lastSeq: try context.eventLog.lastSeq(), recent: [])
        let clean = DurableReplayResumeRecord.restore(
            eventBus: bus,
            settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        )
        let ledger = try XCTUnwrap(ConnectionDurableDomainRevisions.install(
            settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch,
            eventBus: bus,
            previousBootClean: clean
        ))
        return (context, bus, ledger)
    }

    private func cleanQuit(_ context: AppContext, _ bus: EventBus, _ ledger: ConnectionDurableDomainRevisions) {
        context.flushEventPersistence(eventBus: bus)
        XCTAssertTrue(DurableReplayResumeRecord.write(
            eventBus: bus,
            settings: context.settingsRepo,
            bootEpoch: context.liveActivityHostIdentity.bootEpoch
        ))
        ledger.seal(bus: bus.snapshotMetadata().domainRevisions)
    }

    /// Old boot: a state event on the shell, then one snapshot served.
    private func oldBoot() throws -> (AppContext, EventBus, ConnectionDurableDomainRevisions, ConnectionDomainRevisions) {
        let (context, bus, ledger) = try boot()
        bus.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-1"), "name": .string("Main"),
        ]))
        let known = try ledger.resolve(bus: bus.snapshotMetadata().domainRevisions, state: state)
        return (context, bus, ledger, known)
    }

    func test_cleanQuit_restartKeepsEveryUnchangedRevision() throws {
        let (context, bus, ledger, known) = try oldBoot()
        cleanQuit(context, bus, ledger)

        let (_, nextBus, nextLedger) = try boot()
        let served = try nextLedger.resolve(bus: nextBus.snapshotMetadata().domainRevisions, state: state)
        XCTAssertEqual(served, known)
    }

    func test_crash_restartResendsEveryDomain_aboveEveryServedRevision() throws {
        let (_, _, _, known) = try oldBoot()
        // No C8 record and no seal: nothing is proven unchanged.
        let (_, nextBus, nextLedger) = try boot()
        let served = try nextLedger.resolve(bus: nextBus.snapshotMetadata().domainRevisions, state: state)
        XCTAssertEqual(served.domainsChanged(since: known).count, 5)
        let highestKnown = ConnectionDomainRevisions.domainNames.map { known.revision(of: $0) }.max()!
        XCTAssertTrue(ConnectionDomainRevisions.domainNames.allSatisfy { served.revision(of: $0) > highestKnown })
    }

    /// C8 clears its record when a state event lands after the quit wrote it,
    /// so the next boot must not trust the seal either.
    func test_eventAfterQuitSeal_restartResendsEveryDomain() throws {
        let (context, bus, ledger, known) = try oldBoot()
        cleanQuit(context, bus, ledger)
        bus.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-1"), "name": .string("Main"),
        ]))
        context.flushEventPersistence(eventBus: bus)

        let (_, nextBus, nextLedger) = try boot()
        let served = try nextLedger.resolve(bus: nextBus.snapshotMetadata().domainRevisions, state: state)
        XCTAssertEqual(served.domainsChanged(since: known).count, 5)
    }
}
