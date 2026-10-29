import CryptoKit
import Darwin
import Persistence
import RemoteCodeTreaty
import XCTest
@testable import SocketServer

/// In-memory relay socket; whatever one side sends is delivered to `peer`.
private final class MemorySocket: RelayWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [RelayMessage] = []
    private var waiters: [CheckedContinuation<RelayMessage, Error>] = []
    private var closed = false
    private var code: Int?
    weak var peer: MemorySocket?
    /// When set, sends stall briefly and then fail, like a dying relay link.
    var stallThenFailSends = false

    var closeCode: Int? { lock.lock(); defer { lock.unlock() }; return code }

    static func pair() -> (MemorySocket, MemorySocket) {
        let a = MemorySocket(), b = MemorySocket()
        a.peer = b; b.peer = a
        return (a, b)
    }

    private func deliver(_ message: RelayMessage) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
        } else {
            queue.append(message)
            lock.unlock()
        }
    }

    func send(_ data: Data) async throws {
        if stallThenFailSends {
            try? await Task.sleep(nanoseconds: 200_000_000)
            throw URLError(.networkConnectionLost)
        }
        peer?.deliver(.binary(data))
    }
    func sendText(_ text: String) async throws { peer?.deliver(.text(text)) }

    func receiveMessage() async throws -> RelayMessage {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !queue.isEmpty {
                let m = queue.removeFirst()
                lock.unlock()
                cont.resume(returning: m)
            } else if closed {
                lock.unlock()
                cont.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func close(code: Int) {
        markClosed(code)
        peer?.markClosed(code)
    }

    private func markClosed(_ closeCode: Int) {
        lock.lock()
        if code == nil { code = closeCode }
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(throwing: URLError(.networkConnectionLost)) }
    }
}

private final class RelayTestAuth: DirectAuthProvider, @unchecked Sendable {
    let token = "device-bearer"
    private let lock = NSLock()
    private var revoked = false
    private var verifyCount = 0

    var verifyCalls: Int { lock.lock(); defer { lock.unlock() }; return verifyCount }
    func verify(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        verifyCount += 1
        return token == self.token && !revoked
    }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
    var deviceListPadding = 0
    func listDevices() -> [[String: Any]] {
        deviceListPadding == 0 ? [] : [["id": "device-1", "pad": String(repeating: "p", count: deviceListPadding)]]
    }
    func revokeDevice(_ id: String) {
        lock.lock(); revoked = true; lock.unlock()
        // The real adapter revokes through DeviceTrustRepository, which posts this.
        NotificationCenter.default.post(
            name: DeviceTrustRepository.deviceRevokedNotification, object: nil, userInfo: ["deviceId": id])
    }
}

/// A relay socket whose upgrade was answered with a fixed HTTP status and then closed.
private final class RejectedUpgradeSocket: RelayWebSocket, RelayHTTPStatusReporting, @unchecked Sendable {
    let upgradeHTTPStatus: Int?
    init(status: Int) { upgradeHTTPStatus = status }
    func send(_ data: Data) async throws { throw URLError(.badServerResponse) }
    func sendText(_ text: String) async throws { throw URLError(.badServerResponse) }
    func receiveMessage() async throws -> RelayMessage { throw URLError(.badServerResponse) }
    func close(code: Int) {}
}

/// 403 socket that runs `onStatusRead` when the loop reads the status, i.e.
/// after the host socket is released and before the next wait starts.
private final class StatusHookSocket: RelayWebSocket, RelayHTTPStatusReporting, @unchecked Sendable {
    var onStatusRead: (() -> Void)?
    var upgradeHTTPStatus: Int? { onStatusRead?(); onStatusRead = nil; return 403 }
    func send(_ data: Data) async throws { throw URLError(.badServerResponse) }
    func sendText(_ text: String) async throws { throw URLError(.badServerResponse) }
    func receiveMessage() async throws -> RelayMessage { throw URLError(.badServerResponse) }
    func close(code: Int) {}
}

private final class RelayLockedClient: @unchecked Sendable {
    weak var client: RelayHostClient?
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    private var rejectedTokens: [String] = []
    private var requestTokens: [String] = []
    init(_ token: String) { current = token }
    var token: String { lock.withLock { current } }
    var rejected: [String] { lock.withLock { rejectedTokens } }
    var requested: [String] { lock.withLock { requestTokens } }
    func refresh(_ rejected: String) { lock.withLock { rejectedTokens.append(rejected); current = "renewed-token" } }
    func record(_ request: URLRequest) {
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        lock.withLock { requestTokens.append(String(header.dropFirst("Bearer ".count))) }
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor
final class RelayHostClientTests: XCTestCase {
    private typealias Key = Curve25519.KeyAgreement.PrivateKey
    private let serverId = "relay-test-host"

    private final class Rig: @unchecked Sendable {
        let server: DirectHTTPServer
        let auth = RelayTestAuth()
        let hostKey = Key()
        let trustedPhone = Key()
        let hostRelaySide: MemorySocket
        let hostMacSide: MemorySocket
        private let lock = NSLock()
        private var streams: [String: MemorySocket] = [:]   // Mac side by stream id
        var client: RelayHostClient!

        func macSide(_ id: String) -> MemorySocket {
            lock.lock(); defer { lock.unlock() }
            return streams[id]!
        }

        init(serverId: String, dispatcher: JSONRPCDispatcher, deviceId: String = "device-1",
             pingInterval: TimeInterval = 10, rxTimeout: TimeInterval = 25, openTimeout: TimeInterval = 15) {
            (hostRelaySide, hostMacSide) = MemorySocket.pair()
            server = DirectHTTPServer(
                port: UInt16.random(in: 44_001...54_000),
                loopbackOnly: true,
                dispatcher: dispatcher,
                auth: auth,
                serverId: serverId,
                bootEpoch: 1
            )
            let phoneKey = trustedPhone.publicKey.rawRepresentation
            client = RelayHostClient(
                server: server,
                relayBase: URL(string: "wss://relay.test")!,
                serverId: serverId,
                hostStatic: hostKey,
                accessToken: { "account-token" },
                trustedDeviceForRelayKey: { $0 == phoneKey ? deviceId : nil },
                webSocketFactory: { [unowned self] request in
                    let path = request.url?.path ?? ""
                    if path == "/v1/host" { return hostMacSide }
                    let id = String(path.dropFirst("/v1/stream/".count))
                    lock.lock(); defer { lock.unlock() }
                    return streams[id]!
                },
                pingInterval: pingInterval,
                rxTimeout: rxTimeout,
                openTimeout: openTimeout
            )
        }

        /// Relay announces a new stream; returns the iPhone-side socket.
        func openStream(_ id: String) async throws -> MemorySocket {
            let (macSide, phoneSide) = MemorySocket.pair()
            lock.lock(); streams[id] = macSide; lock.unlock()
            try await hostRelaySide.sendText(#"{"type":"open","stream":"\#(id)"}"#)
            return phoneSide
        }
    }

    private func makeRig(deviceId: String = "device-1") async throws -> Rig {
        let rig = Rig(serverId: serverId, dispatcher: JSONRPCDispatcher(router: FakeRouter()), deviceId: deviceId)
        rig.client.start()
        try await rig.hostRelaySide.sendText(#"{"type":"pong"}"#)
        for _ in 0..<200 where !rig.client.isConnected { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(rig.client.isConnected, "host socket open marks the client connected")
        return rig
    }

    private func connect(_ rig: Rig, stream: String, key: Key? = nil) async throws
        -> (RelaySecureChannel, MemorySocket)
    {
        let phone = try await rig.openStream(stream)
        let channel = try await RelaySecureChannel.initiate(
            socket: phone,
            initiatorStatic: key ?? rig.trustedPhone,
            responderStaticPublicKey: rig.hostKey.publicKey.rawRepresentation,
            serverId: serverId
        )
        return (channel, phone)
    }

    /// Reads one HTTP response (header plus Content-Length body, or just the 101 header).
    private func readResponse(_ channel: RelaySecureChannel, phone: MemorySocket) async throws -> String {
        let watchdog = DispatchWorkItem { phone.close(code: 1000) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        var data = Data()
        while true {
            data.append(try await channel.receive())
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            if head.hasPrefix("HTTP/1.1 101") { return head }
            let length = head.lowercased().components(separatedBy: "content-length: ").dropFirst().first
                .flatMap { Int($0.prefix(while: { $0.isNumber })) } ?? 0
            if data.count - end.upperBound >= length {
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    private func get(_ path: String, bearer: Bool, extra: String = "") -> Data {
        let auth = bearer ? "Authorization: Bearer device-bearer\r\n" : ""
        return Data("GET \(path) HTTP/1.1\r\nHost: relay\r\n\(auth)\(extra)\r\n".utf8)
    }

    func testSilentHostSocketIsClosedAfterRxLimitAndPingsKeepFlowing() async throws {
        // WHY: a half-dead relay link must be dropped so the reconnect loop can register the Mac again.
        let rig = Rig(serverId: serverId, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                      pingInterval: 0.05, rxTimeout: 0.3, openTimeout: 0.3)
        rig.client.start()
        defer { rig.client.stop() }
        try await rig.hostRelaySide.sendText(#"{"type":"pong"}"#)
        for _ in 0..<200 where !rig.client.isConnected { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(rig.client.isConnected)
        let firstFrame = try await rig.hostRelaySide.receiveMessage()
        XCTAssertEqual(firstFrame, .text(#"{"type":"ping"}"#))
        for _ in 0..<300 where rig.hostMacSide.closeCode == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(rig.hostMacSide.closeCode, 1000, "no rx for the limit closes the host socket")
        XCTAssertFalse(rig.client.isConnected)
    }

    func testHostSocketThatNeverAnswersIsClosedAtOpenLimit() async throws {
        // WHY: a socket that never delivers a message must not sit as "connecting" forever.
        let rig = Rig(serverId: serverId, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                      pingInterval: 0.05, rxTimeout: 25, openTimeout: 0.3)
        rig.client.start()
        defer { rig.client.stop() }
        for _ in 0..<300 where rig.hostMacSide.closeCode == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(rig.hostMacSide.closeCode, 1000, "silent socket closes at the open limit")
        XCTAssertFalse(rig.client.isConnected)
    }

    func testReconnectDelayReconnectsOpenedSocketAtOnceAndCapsBackoffAt15s() {
        // WHY: an opened socket that drops should come back fast; repeated failures must not back off past 15 s.
        XCTAssertLessThanOrEqual(RelayHostClient.reconnectDelay(opened: true, failures: 0, roll: 1), 0.25)
        XCTAssertEqual(RelayHostClient.reconnectDelay(opened: false, failures: 1, roll: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(RelayHostClient.reconnectDelay(opened: false, failures: 2, roll: 0.5), 2, accuracy: 1e-9)
        XCTAssertEqual(RelayHostClient.reconnectDelay(opened: false, failures: 4, roll: 0.5), 8, accuracy: 1e-9)
        XCTAssertEqual(RelayHostClient.reconnectDelay(opened: false, failures: 9, roll: 0.5), 15, accuracy: 1e-9)
        XCTAssertEqual(RelayHostClient.reconnectDelay(opened: false, failures: 1, roll: 0), 0.8, accuracy: 1e-9)
        XCTAssertEqual(RelayHostClient.reconnectDelay(opened: false, failures: 1, roll: 1), 1.2, accuracy: 1e-9)
    }

    func testReconnectNowSkipsPendingBackoffWait() async throws {
        // WHY: after wake or a network switch the Mac should re-register at once, not after the failure backoff.
        let attempts = AttemptCounter()
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let server = DirectHTTPServer(
            port: UInt16.random(in: 44_001...54_000), loopbackOnly: true, dispatcher: dispatcher,
            auth: RelayTestAuth(), serverId: serverId, bootEpoch: 1)
        let client = RelayHostClient(
            server: server, relayBase: URL(string: "wss://relay.test")!, serverId: serverId,
            hostStatic: Key(), accessToken: { "account-token" }, trustedDeviceForRelayKey: { _ in nil },
            webSocketFactory: { _ in
                attempts.increment()
                let (dead, _) = MemorySocket.pair()
                dead.close(code: 1006)
                return dead
            })
        client.start()
        defer { client.stop() }
        for _ in 0..<100 where attempts.value < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        client.reconnectNow()
        for _ in 0..<50 where attempts.value < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(attempts.value, 2, "reconnectNow reopens the host socket without waiting out the backoff")
    }

    func testRelay401RenewsTheAccessTokenBeforeTheNextAttempt() async throws {
        // WHY: the relay answers 401 once the short-lived account token expires. Retrying the
        // same token kept the Mac off the relay for good, so phones could only reach it on LAN.
        let tokens = TokenBox("expired-token")
        let client = RelayHostClient(
            server: DirectHTTPServer(port: 0, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                     auth: RelayTestAuth(), serverId: serverId, bootEpoch: 1),
            relayBase: URL(string: "wss://relay.test")!, serverId: serverId, hostStatic: Key(),
            accessToken: { tokens.token },
            refreshAccessToken: { tokens.refresh($0) },
            trustedDeviceForRelayKey: { _ in nil },
            webSocketFactory: { request in
                tokens.record(request)
                return RejectedUpgradeSocket(status: tokens.requested.count == 1 ? 401 : 503)
            })
        client.start()
        defer { client.stop() }
        for _ in 0..<300 where tokens.requested.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(tokens.rejected, ["expired-token"], "the rejected token is handed to the refresher")
        XCTAssertEqual(Array(tokens.requested.prefix(2)), ["expired-token", "renewed-token"],
                       "the next attempt carries the renewed token")
        for _ in 0..<150 where tokens.requested.count < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(tokens.rejected.count, 1, "a non-auth failure (503) never spends the refresh token")
    }

    func testRelay403ReportsSubscriptionAndWaitsForAnAccountChange() async throws {
        // WHY: a 403 subscription_required retried every ~15 s forever and only showed a generic
        // "offline". Report the reason and stop dialling until the account changes.
        let attempts = AttemptCounter()
        let tokens = TokenBox("subscriber-token")
        let client = RelayHostClient(
            server: DirectHTTPServer(port: 0, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                     auth: RelayTestAuth(), serverId: serverId, bootEpoch: 1),
            relayBase: URL(string: "wss://relay.test")!, serverId: serverId, hostStatic: Key(),
            accessToken: { tokens.token },
            refreshAccessToken: { tokens.refresh($0) },
            trustedDeviceForRelayKey: { _ in nil },
            webSocketFactory: { _ in
                attempts.increment()
                return RejectedUpgradeSocket(status: 403)
            })
        client.start()
        defer { client.stop() }
        for _ in 0..<200 where RelayHostClient.currentStatus != .subscriptionRequired {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(RelayHostClient.currentStatus, .subscriptionRequired)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(attempts.value, 1, "no reconnect cadence while the subscription is refused")
        XCTAssertTrue(tokens.rejected.isEmpty, "a 403 never spends the refresh token")
        client.accountChanged()
        for _ in 0..<200 where attempts.value < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(attempts.value, 2, "an account change retries at once")
    }

    func testAccountChangeBeforeTheSubscriptionWaitStartsIsNotLost() async throws {
        // WHY: an account change between releasing the host socket and starting the ~10 min
        // 403 recheck cancelled nothing, so the new account waited the full recheck.
        let attempts = AttemptCounter()
        let owner = RelayLockedClient()
        let client = RelayHostClient(
            server: DirectHTTPServer(port: 0, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                     auth: RelayTestAuth(), serverId: serverId, bootEpoch: 1),
            relayBase: URL(string: "wss://relay.test")!, serverId: serverId, hostStatic: Key(),
            accessToken: { "t" }, trustedDeviceForRelayKey: { _ in nil },
            webSocketFactory: { _ in
                attempts.increment()
                let socket = StatusHookSocket()
                if attempts.value == 1 { socket.onStatusRead = { owner.client?.accountChanged() } }
                return socket
            })
        owner.client = client
        client.start()
        defer { client.stop() }
        for _ in 0..<200 where attempts.value < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(attempts.value, 2, "the account change that raced the wait still retries at once")
    }

    func testRepeated401WithSavingRefreshKeepsTheBackoff() async throws {
        // WHY: a refresh that saves posts an account change. Honouring it after every 401 made the
        // Mac re-dial and re-refresh at network speed while the relay kept rejecting the session.
        let attempts = AttemptCounter()
        let owner = RelayLockedClient()
        let client = RelayHostClient(
            server: DirectHTTPServer(port: 0, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                     auth: RelayTestAuth(), serverId: serverId, bootEpoch: 1),
            relayBase: URL(string: "wss://relay.test")!, serverId: serverId, hostStatic: Key(),
            accessToken: { "t" },
            refreshAccessToken: { _ in owner.client?.accountChanged() },
            trustedDeviceForRelayKey: { _ in nil },
            webSocketFactory: { _ in
                attempts.increment()
                return RejectedUpgradeSocket(status: 401)
            })
        owner.client = client
        client.start()
        defer { client.stop() }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertGreaterThanOrEqual(attempts.value, 2, "the first refresh still retries at once")
        XCTAssertLessThanOrEqual(attempts.value, 3, "repeated 401s follow the backoff, not the refresh notifications")
    }

    func testRelayCarriesHTTPAuthAndWebSocketUpgrade() async throws {
        let rig = try await makeRig()
        defer { rig.client.stop() }

        let (c1, p1) = try await connect(rig, stream: "s-discovery")
        try await c1.send(get("/v1/discovery", bearer: false, extra: "Connection: close\r\n"))
        let discovery = try await readResponse(c1, phone: p1)
        XCTAssertTrue(discovery.hasPrefix("HTTP/1.1 200"), discovery)
        XCTAssertTrue(discovery.contains(serverId), "discovery reports the host server_id")

        let (c2, p2) = try await connect(rig, stream: "s-caps-ok")
        try await c2.send(get("/v1/capabilities/authenticated", bearer: true, extra: "Connection: close\r\n"))
        let capsOK = try await readResponse(c2, phone: p2)
        XCTAssertTrue(capsOK.hasPrefix("HTTP/1.1 200"), capsOK)

        let (c3, p3) = try await connect(rig, stream: "s-caps-401")
        try await c3.send(get("/v1/capabilities/authenticated", bearer: false, extra: "Connection: close\r\n"))
        let capsDenied = try await readResponse(c3, phone: p3)
        XCTAssertTrue(capsDenied.hasPrefix("HTTP/1.1 401"), "relay streams are remote-authenticated: bearer is mandatory")

        let (c4, p4) = try await connect(rig, stream: "s-ws")
        let upgrade = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        try await c4.send(get("/v1/ws", bearer: true, extra: upgrade))
        let ws = try await readResponse(c4, phone: p4)
        XCTAssertTrue(ws.hasPrefix("HTTP/1.1 101"), ws)
    }

    func testBodyLargerThanOneNoiseFrameSurvivesTheBridge() async throws {
        let rig = try await makeRig()
        defer { rig.client.stop() }
        let (channel, phone) = try await connect(rig, stream: "s-big")
        let body = String(repeating: "x", count: 200_000)
        let head = "POST /v1/pair/redeem HTTP/1.1\r\nHost: relay\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        try await channel.send(Data((head + body).utf8))
        let response = try await readResponse(channel, phone: phone)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), "server parsed the full chunked body and rejected it as bad JSON")
    }

    func testUntrustedKeyIsClosed4401AndNeverReachesHTTP() async throws {
        let rig = try await makeRig()
        defer { rig.client.stop() }
        let phone = try await rig.openStream("s-untrusted")
        do {
            _ = try await RelaySecureChannel.initiate(
                socket: phone,
                initiatorStatic: Key(),
                responderStaticPublicKey: rig.hostKey.publicKey.rawRepresentation,
                serverId: serverId
            )
            XCTFail("handshake must not complete for an unknown key")
        } catch {}
        for _ in 0..<200 where phone.closeCode == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(phone.closeCode, 4401)
        XCTAssertEqual(rig.auth.verifyCalls, 0, "no HTTP request was served for the untrusted key")
    }

    func testClosingStreamsOfADeviceEndsItsOpenStream() async throws {
        let rig = try await makeRig()
        defer { rig.client.stop() }
        let (channel, phone) = try await connect(rig, stream: "s-revoke")
        try await channel.send(get("/v1/capabilities/authenticated", bearer: true))
        let first = try await readResponse(channel, phone: phone)
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 200"), first)

        rig.client.closeStreams(deviceId: "device-1")
        let watchdog = DispatchWorkItem { phone.close(code: 1000) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            _ = try await channel.receive()
            XCTFail("stream must be closed after the device is revoked")
        } catch {}
        XCTAssertEqual(phone.closeCode, 4401)
    }

    func testRevokeRouteClosesRelayStreamsThroughTheRepositoryNotification() async throws {
        let rig = try await makeRig()
        defer { rig.client.stop() }
        let (idle, idlePhone) = try await connect(rig, stream: "s-idle")
        try await idle.send(get("/v1/capabilities/authenticated", bearer: true))
        _ = try await readResponse(idle, phone: idlePhone)

        let (admin, adminPhone) = try await connect(rig, stream: "s-admin")
        let body = #"{"id":"device-1"}"#
        let request = "POST /v1/devices/revoke HTTP/1.1\r\nHost: relay\r\nAuthorization: Bearer device-bearer\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try await admin.send(Data(request.utf8))
        _ = try? await readResponse(admin, phone: adminPhone)

        let watchdog = DispatchWorkItem { idlePhone.close(code: 1000) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            _ = try await idle.receive()
            XCTFail("the revoked device's idle stream must be closed")
        } catch {}
    }

    func testRepositoryRevokeClosesRelayStreamsWithoutTheHTTPRoute() async throws {
        // WHY: Mac Settings revokes through the repository, not HTTP; open streams must still die.
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: dir).run()
        let repo = DeviceTrustRepository(db: db)
        let code = try repo.createPairingCode()
        let deviceId = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "phone")).0.id
        let rig = try await makeRig(deviceId: deviceId)
        defer { rig.client.stop() }
        let (channel, phone) = try await connect(rig, stream: "s-repo-revoke")
        try await channel.send(get("/v1/capabilities/authenticated", bearer: true))
        _ = try await readResponse(channel, phone: phone)

        try repo.revoke(id: deviceId)
        let watchdog = DispatchWorkItem { phone.close(code: 1000) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            _ = try await channel.receive()
            XCTFail("stream must close when the repository revokes the device")
        } catch {}
        XCTAssertEqual(phone.closeCode, 4401)
    }

    func testSendFailureWithBackedUpOutputStillReleasesTheStream() async throws {
        // WHY: a failed relay send used to leave the reader spinning on backpressure, leaking the fd and threads.
        let rig = try await makeRig()
        defer { rig.client.stop() }
        rig.auth.deviceListPadding = 3_000_000
        let (channel, phone) = try await connect(rig, stream: "s-stall")
        XCTAssertEqual(rig.client.openStreamCount, 1)
        rig.macSide("s-stall").stallThenFailSends = true
        try await channel.send(get("/v1/devices", bearer: true))

        for _ in 0..<500 where rig.client.openStreamCount > 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(rig.client.openStreamCount, 0, "stream is removed once its send fails")
        XCTAssertEqual(phone.closeCode, 1000)
    }

    func testRelayStatusGoesYellowThenGreenThenRedOnStop() async throws {
        // WHY: the avatar badge must show green only while the host socket is open and red once stopped.
        let rig = Rig(serverId: serverId, dispatcher: JSONRPCDispatcher(router: FakeRouter()))
        rig.client.start()
        for _ in 0..<200 where RelayHostClient.currentStatus != .connecting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(RelayHostClient.currentStatus, .connecting)
        try await rig.hostRelaySide.sendText(#"{"type":"pong"}"#)
        for _ in 0..<200 where RelayHostClient.currentStatus != .connected { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(RelayHostClient.currentStatus, .connected)
        rig.client.stop()
        XCTAssertEqual(RelayHostClient.currentStatus, .offline)
    }

    // MARK: - Mux v1

    /// Phone side of one mux session: frames go out as host DATA frames and
    /// come back from the host socket for this session id only.
    private final class SessionSocket: RelayWebSocket, @unchecked Sendable {
        let id = UUID()
        let relay: MemorySocket
        private let lock = NSLock()
        private var queue: [Data] = []
        private var waiters: [CheckedContinuation<RelayMessage, Error>] = []
        private(set) var closedCode: UInt16?
        init(relay: MemorySocket) { self.relay = relay }
        func push(_ data: Data) {
            lock.lock()
            if let w = waiters.first { waiters.removeFirst(); lock.unlock(); w.resume(returning: .binary(data)) }
            else { queue.append(data); lock.unlock() }
        }
        func closedByHost(_ code: UInt16) {
            lock.lock(); closedCode = code; let w = waiters; waiters = []; lock.unlock()
            for x in w { x.resume(throwing: URLError(.networkConnectionLost)) }
        }
        func send(_ data: Data) async throws { try await relay.send(RelayMux.encode(.data(session: id, payload: data))) }
        func sendText(_ text: String) async throws {}
        func receiveMessage() async throws -> RelayMessage {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if !queue.isEmpty { let d = queue.removeFirst(); lock.unlock(); c.resume(returning: .binary(d)) }
                else if closedCode != nil { lock.unlock(); c.resume(throwing: URLError(.networkConnectionLost)) }
                else { waiters.append(c); lock.unlock() }
            }
        }
        func close(code: Int) {}
    }

    /// Routes host-socket frames to sessions; skips pings.
    private final class HostDemux: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [UUID: SessionSocket] = [:]
        private var task: Task<Void, Never>?
        func add(_ s: SessionSocket) { lock.lock(); sessions[s.id] = s; lock.unlock() }
        func start(_ relay: MemorySocket) {
            task = Task {
                while let m = try? await relay.receiveMessage() {
                    guard case .binary(let d) = m, let f = RelayMux.decodeHost(d) else { continue }
                    switch f {
                    case .data(let id, let p): self.lock.withLock { self.sessions[id] }?.push(p)
                    case .close(let id, let code): self.lock.withLock { self.sessions[id] }?.closedByHost(code)
                    case .open: break
                    }
                }
            }
        }
        deinit { task?.cancel() }
    }

    private func makeMuxRig() async throws -> (Rig, HostDemux) {
        let rig = Rig(serverId: serverId, dispatcher: JSONRPCDispatcher(router: FakeRouter()))
        rig.client.start()
        try await rig.hostRelaySide.sendText(#"{"type":"hello","mux":1}"#)
        for _ in 0..<200 where !rig.client.isConnected { try await Task.sleep(nanoseconds: 10_000_000) }
        let demux = HostDemux()
        demux.start(rig.hostRelaySide)
        return (rig, demux)
    }

    private func muxSession(_ rig: Rig, _ demux: HostDemux, innerMux: Bool, key: Key? = nil) async throws
        -> (RelaySecureChannel, SessionSocket)
    {
        let socket = SessionSocket(relay: rig.hostRelaySide)
        demux.add(socket)
        try await rig.hostRelaySide.send(RelayMux.encode(.open(session: socket.id, innerMux: innerMux)))
        let channel = try await RelaySecureChannel.initiate(
            socket: socket, initiatorStatic: key ?? rig.trustedPhone,
            responderStaticPublicKey: rig.hostKey.publicKey.rawRepresentation, serverId: serverId)
        return (channel, socket)
    }

    func testMuxHostRequestAdvertisesMuxHeader() async throws {
        // WHY: the relay only routes sessions through the host socket when the Mac asks for it.
        var seen: URLRequest?
        let (_, macSide) = MemorySocket.pair()
        let client = RelayHostClient(
            server: DirectHTTPServer(port: 0, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                     auth: RelayTestAuth(), serverId: serverId, bootEpoch: 1),
            relayBase: URL(string: "wss://relay.test")!, serverId: serverId, hostStatic: Key(),
            accessToken: { "t" }, trustedDeviceForRelayKey: { _ in nil },
            webSocketFactory: { seen = $0; return macSide })
        client.start()
        defer { client.stop() }
        for _ in 0..<200 where seen == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(seen?.value(forHTTPHeaderField: RelayMux.hostHeader), "1")
    }

    func testMuxSessionWithoutInnerMuxServesOneHTTPConnectionOverTheHostSocket() async throws {
        // WHY: phones that do not split sessions must keep working when the Mac moves to session frames.
        let (rig, demux) = try await makeMuxRig()
        defer { rig.client.stop() }
        let (channel, _) = try await muxSession(rig, demux, innerMux: false)
        try await channel.send(get("/v1/discovery", bearer: false, extra: "Connection: close\r\n"))
        var body = Data()
        while let chunk = try? await channel.receive() { body.append(chunk); if String(decoding: body, as: UTF8.self).contains(serverId) { break } }
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
    }

    func testInnerMuxRunsConcurrentHTTPConnectionsInOneSession() async throws {
        // WHY: one Noise session must carry discovery, RPC and more at once, with no new relay socket per request.
        let (rig, demux) = try await makeMuxRig()
        defer { rig.client.stop() }
        let (channel, _) = try await muxSession(rig, demux, innerMux: true)
        for id: UInt32 in [1, 2, 3] {
            try await channel.send(RelayMux.encode(.open(stream: id)))
            for frame in RelayMux.innerDataFrames(stream: id, bytes: get("/v1/discovery", bearer: false, extra: "Connection: close\r\n")) {
                try await channel.send(frame)
            }
        }
        var bodies: [UInt32: Data] = [:]
        var closed = Set<UInt32>()
        while closed.count < 3 {
            guard let plain = try? await channel.receive(), let frame = RelayMux.decodeInner(plain) else { break }
            switch frame {
            case .data(let id, let payload): bodies[id, default: Data()].append(payload)
            case .close(let id): closed.insert(id)
            case .open: XCTFail("the Mac never opens streams")
            }
        }
        XCTAssertEqual(closed, [1, 2, 3], "each inner stream ends with its own CLOSE")
        for id: UInt32 in [1, 2, 3] {
            let text = String(decoding: bodies[id] ?? Data(), as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200") && text.contains(serverId), "stream \(id): \(text.prefix(80))")
        }
    }

    func testInnerMuxReusedStreamIdClosesTheSession() async throws {
        // WHY: a reused id could splice two HTTP connections together.
        let (rig, demux) = try await makeMuxRig()
        defer { rig.client.stop() }
        let (channel, socket) = try await muxSession(rig, demux, innerMux: true)
        try await channel.send(RelayMux.encode(.open(stream: 1)))
        try await channel.send(RelayMux.encode(.open(stream: 1)))
        for _ in 0..<300 where socket.closedCode == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(socket.closedCode)
    }

    func testMuxSessionWithUntrustedKeyIsClosed4401() async throws {
        // WHY: a key that is not a paired device must never reach the HTTP server through a session either.
        let (rig, demux) = try await makeMuxRig()
        defer { rig.client.stop() }
        let socket = SessionSocket(relay: rig.hostRelaySide)
        demux.add(socket)
        try await rig.hostRelaySide.send(RelayMux.encode(.open(session: socket.id, innerMux: true)))
        _ = try? await RelaySecureChannel.initiate(
            socket: socket, initiatorStatic: Key(),
            responderStaticPublicKey: rig.hostKey.publicKey.rawRepresentation, serverId: serverId)
        for _ in 0..<300 where socket.closedCode == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(socket.closedCode, 4401)
    }
}
