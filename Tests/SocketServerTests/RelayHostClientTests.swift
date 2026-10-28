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
}
