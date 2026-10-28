import CryptoKit
import Foundation
import XCTest
@testable import RemoteCodeTreaty

/// In-memory socket; `peer` receives what this side sends.
final class MemoryRelayWebSocket: RelayWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [RelayMessage] = []
    private var waiters: [CheckedContinuation<RelayMessage, Error>] = []
    private var closed = false
    private(set) var closeCode: Int?
    weak var peer: MemoryRelayWebSocket?
    var tamperNext = false

    static func pair() -> (MemoryRelayWebSocket, MemoryRelayWebSocket) {
        let a = MemoryRelayWebSocket(), b = MemoryRelayWebSocket()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    fileprivate func deliver(_ message: RelayMessage) {
        lock.lock()
        if let waiter = waiters.first, !closed {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
        } else {
            queue.append(message)
            lock.unlock()
        }
    }

    func send(_ data: Data) async throws {
        var out = data
        if tamperNext, !out.isEmpty {
            tamperNext = false
            out[out.startIndex] ^= 0x01
        }
        peer?.deliver(.binary(out))
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
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        closeCode = code
        let pending = waiters
        waiters = []
        lock.unlock()
        for w in pending { w.resume(throwing: URLError(.networkConnectionLost)) }
        peer?.peerClosed(code)
    }

    private func peerClosed(_ code: Int) {
        lock.lock()
        let wasClosed = closed
        closed = true
        if closeCode == nil { closeCode = code }
        let pending = waiters
        waiters = []
        lock.unlock()
        if wasClosed { return }
        for w in pending { w.resume(throwing: URLError(.networkConnectionLost)) }
    }
}

final class RelayChannelTests: XCTestCase {
    private typealias Key = Curve25519.KeyAgreement.PrivateKey

    private func handshake(trusted: Bool = true, tamper: Bool = false) async throws
        -> (RelaySecureChannel, RelaySecureChannel, MemoryRelayWebSocket, MemoryRelayWebSocket)
    {
        let (phone, mac) = MemoryRelayWebSocket.pair()
        let i = Key(), r = Key()
        let iPub = i.publicKey.rawRepresentation
        async let macSide = RelaySecureChannel.respond(
            socket: mac, responderStatic: r, serverId: "srv", isTrusted: { trusted && $0 == iPub })
        async let phoneSide = RelaySecureChannel.initiate(
            socket: phone, initiatorStatic: i,
            responderStaticPublicKey: r.publicKey.rawRepresentation, serverId: "srv")
        let (m, p) = try await (macSide, phoneSide)
        XCTAssertEqual(m.1, iPub)
        return (p, m.0, phone, mac)
    }

    func testRoundTripChunksLargePayloadBothDirections() async throws {
        let (phone, mac, _, _) = try await handshake()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try await phone.send(payload)
        var got = Data()
        while got.count < payload.count { got.append(try await mac.receive()) }
        XCTAssertEqual(got, payload)
        try await mac.send(payload)
        got = Data()
        while got.count < payload.count { got.append(try await phone.receive()) }
        XCTAssertEqual(got, payload)
    }

    func testUntrustedKeyClosesWith4401() async throws {
        let (phone, mac) = MemoryRelayWebSocket.pair()
        let i = Key(), r = Key()
        async let macSide: Void = {
            do {
                _ = try await RelaySecureChannel.respond(
                    socket: mac, responderStatic: r, serverId: "srv", isTrusted: { _ in false })
                XCTFail("must reject")
            } catch {
                XCTAssertEqual(error as? RelayChannelError, .untrustedKey)
            }
        }()
        do {
            _ = try await RelaySecureChannel.initiate(
                socket: phone, initiatorStatic: i,
                responderStaticPublicKey: r.publicKey.rawRepresentation, serverId: "srv")
            XCTFail("no message 2 expected")
        } catch {}
        await macSide
        XCTAssertEqual(mac.closeCode, 4401)
    }

    func testHandshakeWithSilentPeerTimesOutAndClosesSocket() async throws {
        // WHY: a relay that never answers must not hang the stream forever; the socket must close so reads end.
        let phone = MemoryRelayWebSocket()
        do {
            _ = try await RelaySecureChannel.initiate(
                socket: phone, initiatorStatic: Key(),
                responderStaticPublicKey: Key().publicKey.rawRepresentation, serverId: "srv", timeout: 0.1)
            XCTFail("silent peer must time out")
        } catch {
            XCTAssertEqual(error as? RelayChannelError, .handshakeTimedOut)
        }
        XCTAssertEqual(phone.closeCode, 4400)
    }

    func testTamperedFrameClosesWith4400() async throws {
        let (phone, mac, phoneSock, macSock) = try await handshake()
        phoneSock.tamperNext = true
        try await phone.send(Data("hello".utf8))
        do {
            _ = try await mac.receive()
            XCTFail("tampered frame must fail")
        } catch {}
        XCTAssertEqual(macSock.closeCode, 4400)
    }

    func testEndpointsEncodeQuery() {
        let base = URL(string: "wss://relay.example.com")!
        XCTAssertEqual(RelayEndpoints.host(base: base, serverId: "a b").absoluteString,
                       "wss://relay.example.com/v1/host?server_id=a%20b")
        XCTAssertEqual(RelayEndpoints.stream(base: base, serverId: "s", streamId: "x1").absoluteString,
                       "wss://relay.example.com/v1/stream/x1?server_id=s")
    }
}
