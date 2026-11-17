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

@MainActor
private final class DurableRevisionRouter: FakeRouter, ConnectionSnapshotRouting {
    var workspaceName = "Main"

    func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
        snapshotState(workspaceName: workspaceName)
    }
}

/// V2/V3 on the wire: a client that saw `snapshot.domain_revisions.durable_v1`
/// sends the revisions it learned on the previous boot; the restarted Mac
/// answers only the domains that changed. Servers without the ledger keep the
/// old welcome and revisions, so old clients see no difference.
@MainActor
final class DurableDomainRevisionsWireTests: XCTestCase {
    private func startServer(
        router: DurableRevisionRouter,
        bootEpoch: UInt64,
        durable: ConnectionDurableDomainRevisions?
    ) async throws -> (DirectHTTPServer, UInt16) {
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "durable-host",
            bootEpoch: bootEpoch
        )
        server.durableDomainRevisions = durable
        try server.start()
        try await Task.sleep(nanoseconds: 80_000_000)
        return (server, port)
    }

    private func ledger(_ store: RevisionStore, boot: UInt64, clean: Bool) throws -> ConnectionDurableDomainRevisions {
        try ConnectionDurableDomainRevisions(
            bootEpoch: boot,
            bootFloor: EventBus.shared.currentSeq,
            previousBootClean: clean,
            load: { store.load() },
            save: { try store.save($0) }
        )
    }

    private func welcomeCapabilities(port: UInt16) async throws -> [String] {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let data: Data
        switch try await socket.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: data = Data()
        }
        let welcome = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(welcome["capabilities"] as? [String])
    }

    private func rpc(port: UInt16, method: String, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func snapshot(port: UInt16, known: [String: Any]?, previousBoot: UInt64) async throws -> [String: Any] {
        var params: [String: Any] = ["supportedStateVersion": 3, "expectedBootEpoch": previousBoot]
        params["knownDomainRevisions"] = known
        let response = try await rpc(port: port, method: "sync.snapshot", params: params)
        XCTAssertNil(response["error"], "\(response)")
        return try XCTUnwrap((response["result"] as? [String: Any])?["state"] as? [String: Any])
    }

    /// `sync.snapshot.begin` + every chunk, decoded like the iOS assembler.
    private func chunkedSnapshot(port: UInt16, known: [String: Any], previousBoot: UInt64) async throws -> [String: JSONValue] {
        let begin = try await rpc(port: port, method: "sync.snapshot.begin", params: [
            "supportedStateVersion": 3, "expectedBootEpoch": previousBoot, "knownDomainRevisions": known,
        ])
        let manifest = try XCTUnwrap(begin["result"] as? [String: Any], "\(begin)")
        let transferId = try XCTUnwrap(manifest["transferId"] as? String)
        let chunkCount = try XCTUnwrap((manifest["chunkCount"] as? NSNumber)?.intValue)
        var frameData = Data()
        for index in 0..<chunkCount {
            let chunk = try await rpc(port: port, method: "sync.snapshot.chunk", params: [
                "transferId": transferId, "chunkIndex": index,
            ])
            let body = try XCTUnwrap(chunk["result"] as? [String: Any], "\(chunk)")
            frameData.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["payloadBase64"] as? String))))
        }
        guard case .snapshot(let frame) = try ConnectionTransportFrame.decodeStrict(frameData) else {
            XCTFail("assembled bytes must be a snapshot frame")
            return [:]
        }
        return try XCTUnwrap(frame.state.objectValue)
    }

    func test_restartedMac_answersPreviousBootKnownRevisionsWithOnlyChangedDomains() async throws {
        let router = DurableRevisionRouter()
        let store = RevisionStore()

        // Boot 41: the client takes a full snapshot.
        let firstLedger = try ledger(store, boot: 41, clean: false)
        let (first, firstPort) = try await startServer(router: router, bootEpoch: 41, durable: firstLedger)
        let capabilities = try await welcomeCapabilities(port: firstPort)
        XCTAssertTrue(capabilities.contains(ConnectionDurableDomainRevisions.capability),
                      "iOS sends previous-boot revisions only when welcome lists the capability")
        let full = try await snapshot(port: firstPort, known: nil, previousBoot: 41)
        XCTAssertNil(full["partial"])
        let known = try XCTUnwrap(full["domainRevisions"] as? [String: Any])
        // Same boot, old-client path still works on durable values.
        let sameBoot = try await snapshot(port: firstPort, known: known, previousBoot: 41)
        XCTAssertEqual(sameBoot["includedDomains"] as? [String], [])
        first.stop()
        firstLedger.seal(bus: EventBus.shared.snapshotMetadata().domainRevisions)

        // Boot 42, nothing changed: revisions-only partial on both snapshot RPCs.
        let secondLedger = try ledger(store, boot: 42, clean: true)
        let (second, secondPort) = try await startServer(router: router, bootEpoch: 42, durable: secondLedger)
        let unchanged = try await snapshot(port: secondPort, known: known, previousBoot: 41)
        XCTAssertEqual(unchanged["partial"] as? Bool, true)
        XCTAssertEqual(unchanged["includedDomains"] as? [String], [])
        XCTAssertNil(unchanged["workspaces"])
        XCTAssertEqual(unchanged["domainRevisions"] as? NSDictionary, known as NSDictionary,
                       "revisions are neither lowered nor bumped by the restart")
        let chunked = try await chunkedSnapshot(port: secondPort, known: known, previousBoot: 41)
        XCTAssertEqual(chunked["includedDomains"], .array([]))
        second.stop()
        secondLedger.seal(bus: EventBus.shared.snapshotMetadata().domainRevisions)

        // Boot 43 after a change made while the Mac was restarting.
        router.workspaceName = "Renamed while restarting"
        let thirdLedger = try ledger(store, boot: 43, clean: true)
        let (third, thirdPort) = try await startServer(router: router, bootEpoch: 43, durable: thirdLedger)
        defer { third.stop() }
        let changed = try await snapshot(port: thirdPort, known: known, previousBoot: 42)
        XCTAssertEqual(changed["includedDomains"] as? [String], ["shell"])
        let workspaces = try XCTUnwrap(changed["workspaces"] as? [[String: Any]])
        XCTAssertEqual(workspaces.first?["name"] as? String, "Renamed while restarting")
        let chunkedChanged = try await chunkedSnapshot(port: thirdPort, known: known, previousBoot: 42)
        XCTAssertEqual(chunkedChanged["includedDomains"], .array([.string("shell")]))
    }

    func test_withoutDurableRevisions_welcomeAndRevisionsKeepTheOldShape() async throws {
        let router = DurableRevisionRouter()
        let (server, port) = try await startServer(router: router, bootEpoch: 7, durable: nil)
        defer { server.stop() }
        let capabilities = try await welcomeCapabilities(port: port)
        XCTAssertEqual(capabilities, DirectHTTPServer.welcomeCapabilities())
        XCTAssertFalse(capabilities.contains(ConnectionDurableDomainRevisions.capability))
        let state = try await snapshot(port: port, known: nil, previousBoot: 7)
        let revisions = try XCTUnwrap(state["domainRevisions"] as? [String: Any])
        let bus = EventBus.shared.snapshotMetadata().domainRevisions
        XCTAssertEqual((revisions["agentThreads"] as? NSNumber)?.int64Value, bus.agentThreads)
        XCTAssertEqual((revisions["shell"] as? NSNumber)?.int64Value, bus.shell)
    }
}
