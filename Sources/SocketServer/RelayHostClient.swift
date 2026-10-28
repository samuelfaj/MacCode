import CryptoKit
import Darwin
import Foundation
import Persistence
import RemoteCodeTreaty

/// Keeps the Mac's `/v1/host` socket open on the relay and bridges every relay
/// stream into the local HTTP server through a socketpair. Untrusted initiator keys never reach the HTTP server.
public final class RelayHostClient: @unchecked Sendable {
    private final class Stream {
        let socket: RelayWebSocket
        var deviceId: String?
        var fd: Int32 = -1
        var terminated = false
        init(socket: RelayWebSocket) { self.socket = socket }
    }

    private let server: DirectHTTPServer
    private let relayBase: URL
    private let serverId: String
    private let hostStatic: Curve25519.KeyAgreement.PrivateKey
    private let accessToken: @Sendable () -> String?
    private let trustedDeviceForRelayKey: @Sendable (Data) -> String?
    private let webSocketFactory: @Sendable (URLRequest) -> RelayWebSocket
    private let pingInterval: TimeInterval
    private let rxTimeout: TimeInterval
    private let openTimeout: TimeInterval

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var hostSocket: RelayWebSocket?
    private var streams: [String: Stream] = [:]
    private var connected = false
    private var running = false
    /// Set by `reconnectNow()`: the next reconnect wait is skipped.
    private var skipWait = false
    private var revokeObserver: NSObjectProtocol?

    public var onStatusChange: ((Bool) -> Void)?

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    public init(
        server: DirectHTTPServer,
        relayBase: URL,
        serverId: String,
        hostStatic: Curve25519.KeyAgreement.PrivateKey,
        accessToken: @escaping @Sendable () -> String?,
        trustedDeviceForRelayKey: @escaping @Sendable (Data) -> String?,
        webSocketFactory: @escaping @Sendable (URLRequest) -> RelayWebSocket = { URLSessionRelayWebSocket($0) },
        pingInterval: TimeInterval = 10,
        rxTimeout: TimeInterval = 25,
        openTimeout: TimeInterval = 15
    ) {
        self.server = server
        self.relayBase = relayBase
        self.serverId = serverId
        self.hostStatic = hostStatic
        self.accessToken = accessToken
        self.trustedDeviceForRelayKey = trustedDeviceForRelayKey
        self.webSocketFactory = webSocketFactory
        self.pingInterval = pingInterval
        self.rxTimeout = rxTimeout
        self.openTimeout = openTimeout
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        revokeObserver = NotificationCenter.default.addObserver(
            forName: DeviceTrustRepository.deviceRevokedNotification, object: nil, queue: nil
        ) { [weak self] note in
            if let id = note.userInfo?["deviceId"] as? String { self?.closeStreams(deviceId: id) }
        }
        task = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() {
        lock.lock()
        running = false
        let loop = task
        task = nil
        let sleeper = sleepTask
        let host = hostSocket
        let open = Array(streams.values)
        let observer = revokeObserver
        revokeObserver = nil
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        loop?.cancel()
        sleeper?.cancel()
        host?.close(code: 1000)
        for stream in open { terminate(stream, code: 1001) }
        setConnected(false)
    }

    /// The Private session changed: reconnect with the current token.
    public func accountChanged() {
        lock.lock()
        let sleeper = sleepTask
        let host = hostSocket
        let open = Array(streams.values)
        lock.unlock()
        host?.close(code: 1000)
        sleeper?.cancel()
        for stream in open { terminate(stream, code: 1001) }
    }

    /// Wake or network change: drop the current host socket and reconnect without waiting out backoff.
    public func reconnectNow() {
        lock.lock()
        guard running else { lock.unlock(); return }
        skipWait = true
        let sleeper = sleepTask
        let host = hostSocket
        lock.unlock()
        host?.close(code: 1000)
        sleeper?.cancel()
    }

    var openStreamCount: Int {
        lock.lock(); defer { lock.unlock() }
        return streams.count
    }

    /// Closes open relay streams of a revoked device (also on `DeviceTrustRepository.deviceRevokedNotification`).
    public func closeStreams(deviceId: String) {
        lock.lock()
        let matching = streams.values.filter { $0.deviceId == deviceId }
        lock.unlock()
        for stream in matching { terminate(stream, code: 4401) }
    }

    // MARK: - Control loop

    private func setConnected(_ value: Bool) {
        lock.lock()
        let changed = connected != value
        connected = value
        lock.unlock()
        if changed { onStatusChange?(value) }
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Reconnect delay. `roll` is a uniform sample in 0...1. An opened socket reconnects at once (0–250 ms);
    /// otherwise exponential 1, 2, 4, 8 s, capped at 15 s, with ±20% jitter.
    static func reconnectDelay(opened: Bool, failures: Int, roll: Double) -> Double {
        if opened { return roll * 0.25 }
        let base = min(15, pow(2, Double(max(failures, 1) - 1)))
        return base * (0.8 + 0.4 * roll)
    }

    private func wait(_ seconds: Double) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        lock.lock()
        if skipWait { skipWait = false; lock.unlock(); sleeper.cancel(); return }
        sleepTask = sleeper
        lock.unlock()
        if !isRunning() { sleeper.cancel() }
        await sleeper.value
        lock.lock(); sleepTask = nil; skipWait = false; lock.unlock()
    }

    private func authorizedRequest(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func runLoop() async {
        var failures = 0
        while !Task.isCancelled, isRunning() {
            guard let token = accessToken(), !token.isEmpty else {
                await wait(60)
                continue
            }
            var hostRequest = authorizedRequest(RelayEndpoints.host(base: relayBase, serverId: serverId), token: token)
            hostRequest.setValue("1", forHTTPHeaderField: RelayMux.hostHeader)
            let socket = webSocketFactory(hostRequest)
            lock.lock(); hostSocket = socket; lock.unlock()
            let opened = await serveHost(socket)
            failures = opened ? 0 : failures + 1
            lock.lock(); hostSocket = nil; lock.unlock()
            socket.close(code: 1000)
            setConnected(false)
            guard !Task.isCancelled, isRunning() else { break }
            await wait(Self.reconnectDelay(opened: opened, failures: failures, roll: Double.random(in: 0...1)))
        }
    }

    /// Returns true when the relay answered at least once (a successful open).
    private func serveHost(_ socket: RelayWebSocket) async -> Bool {
        let rx = RxClock(openLimit: openTimeout, steadyLimit: rxTimeout)
        let pinger = Task {
            var nextPing = Date.distantPast
            let tick = min(1, pingInterval)
            while !Task.isCancelled {
                if Date() >= nextPing {
                    do { try await socket.sendText(#"{"type":"ping"}"#) } catch { return }
                    nextPing = Date().addingTimeInterval(pingInterval)
                }
                if rx.expired { socket.close(code: 1000); return }
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            }
        }
        var sessions: [UUID: RelayVirtualSocket] = [:]
        defer {
            pinger.cancel()
            // The host socket carried these sessions; without it they are gone.
            for session in sessions.values { session.remoteClosed() }
        }
        var opened = false
        var mux = false
        while !Task.isCancelled {
            guard let message = try? await socket.receiveMessage() else { break }
            rx.touch()
            if !opened {
                opened = true
                setConnected(true)
            }
            if case .binary(let data) = message {
                guard mux, let frame = RelayMux.decodeHost(data) else { continue }
                switch frame {
                case .open(let id, let innerMux):
                    guard sessions[id] == nil else { continue }
                    let session = RelayVirtualSocket(id: id, host: socket)
                    sessions[id] = session
                    Task { [weak self] in
                        await self?.serveSession(id.uuidString.lowercased(), socket: session, innerMux: innerMux)
                    }
                case .data(let id, let payload):
                    sessions[id]?.deliver(payload)
                case .close(let id, _):
                    sessions.removeValue(forKey: id)?.remoteClosed()
                }
                continue
            }
            if case .text(let text) = message, case .hello(let version)? = RelayMux.control(text) {
                mux = version >= 1
                continue
            }
            sessions = sessions.filter { !$0.value.isClosed }
            guard case .text(let text) = message,
                  let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  object["type"] as? String == "open",
                  let streamId = object["stream"] as? String,
                  Self.isValidStreamId(streamId) else { continue }
            Task { [weak self] in await self?.handleStream(streamId) }
        }
        return opened
    }

    static func isValidStreamId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }

    // MARK: - Streams

    private func handleStream(_ id: String) async {
        guard let token = accessToken(), !token.isEmpty, isRunning() else { return }
        let socket = webSocketFactory(
            authorizedRequest(RelayEndpoints.stream(base: relayBase, serverId: serverId, streamId: id), token: token))
        await serveSession(id, socket: socket, innerMux: false)
    }

    /// One phone session: Noise respond, device trust, then either one HTTP
    /// connection (legacy) or many, split by inner mux frames.
    private func serveSession(_ id: String, socket: RelayWebSocket, innerMux: Bool) async {
        guard isRunning() else { socket.close(code: 1001); return }
        let started = Date()
        let stream = Stream(socket: socket)
        lock.lock(); streams[id] = stream; lock.unlock()

        var resolvedDevice: String?
        let channel: RelaySecureChannel
        let initiatorKey: Data
        do {
            (channel, initiatorKey) = try await RelaySecureChannel.respond(
                socket: socket, responderStatic: hostStatic, serverId: serverId,
                isTrusted: { key in
                    resolvedDevice = self.trustedDeviceForRelayKey(key)
                    return resolvedDevice != nil
                })
        } catch {
            finish(id, stream)
            NSLog("[RC2.Relay] stream=%@ handshake_failed", id)
            return
        }
        guard let deviceId = resolvedDevice else {
            socket.close(code: 4401)
            finish(id, stream)
            return
        }
        if innerMux {
            lock.lock()
            stream.deviceId = deviceId
            let aborted = stream.terminated
            lock.unlock()
            if aborted || trustedDeviceForRelayKey(initiatorKey) != deviceId {
                socket.close(code: 4401)
                finish(id, stream)
                return
            }
            await RelayInnerMuxBridge(channel: channel, server: server, peer: "relay:" + deviceId).run()
            channel.close(code: 1000)
            finish(id, stream)
            NSLog("[RC2.Relay] session=%@ device=%@ mux=1 duration=%.1fs", id, deviceId, Date().timeIntervalSince(started))
            return
        }

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            socket.close(code: 1013)
            finish(id, stream)
            return
        }
        let (a, b) = (pair[0], pair[1])
        var yes: Int32 = 1
        for fd in [a, b] {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            DirectHTTPServer.enableCloseOnExec(fd)
        }
        guard server.registerRelayConnection(fd: a) else {
            Darwin.close(b)
            socket.close(code: 1013)
            finish(id, stream)
            return
        }
        lock.lock()
        stream.deviceId = deviceId
        stream.fd = b
        let aborted = stream.terminated
        lock.unlock()
        // stop() or a revoke may have run between the handshake and now; the
        // shutdown makes the HTTP session and both pumps end right away.
        if aborted || trustedDeviceForRelayKey(initiatorKey) != deviceId {
            socket.close(code: 4401)
            shutdown(b, SHUT_RDWR)
        }

        // `b` is non-blocking: the async tasks never park a cooperative thread,
        // and the reader thread waits in poll().
        _ = fcntl(b, F_SETFL, fcntl(b, F_GETFL) | O_NONBLOCK)
        let counters = ByteCounters()
        let live = LiveCount(3)
        let peer = "relay:" + deviceId
        let server = self.server
        Thread.detachNewThread {
            server.serveRelayConnection(fd: a, peer: peer)
        }
        let (outbound, outboundSink) = AsyncStream.makeStream(of: Data.self)
        let teardown: @Sendable () -> Void = {
            counters.markEnded()
            shutdown(b, SHUT_RDWR)
            outboundSink.finish()
        }
        let end: @Sendable () -> Void = { [weak self] in
            teardown()
            guard live.decrement() == 0 else { return }
            self?.finish(id, stream)
            Darwin.close(b)
            NSLog("[RC2.Relay] stream=%@ device=%@ bytes_in=%lld bytes_out=%lld duration=%.1fs",
                  id, deviceId, counters.toMac, counters.fromMac, Date().timeIntervalSince(started))
        }
        // Mac -> iPhone: blocking-style read loop on its own thread.
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                if counters.ended { break }
                if counters.pendingOutbound > 1_048_576 { usleep(5_000); continue }
                var pfd = pollfd(fd: b, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 500)
                if ready < 0, errno == EINTR { continue }
                if ready < 0 { break }
                if ready == 0 { continue }
                let n = read(b, &buffer, buffer.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                if n <= 0 { break }
                counters.addPending(n)
                outboundSink.yield(Data(buffer[0..<n]))
            }
            end()
        }
        Task {
            for await chunk in outbound {
                do { try await channel.send(chunk) } catch { break }
                counters.sentFromMac(chunk.count)
            }
            // Everything the HTTP server wrote has been sent; now close the relay side.
            channel.close(code: 1000)
            end()
        }
        // iPhone -> Mac
        Task {
            while let data = try? await channel.receive() {
                if await !Self.writeAll(b, data) { break }
                counters.addToMac(data.count)
            }
            end()
        }
    }

    private func finish(_ id: String, _ stream: Stream) {
        lock.lock()
        if streams[id] === stream { streams[id] = nil }
        lock.unlock()
    }

    private func terminate(_ stream: Stream, code: Int) {
        lock.lock()
        stream.terminated = true
        // Under the lock: `end` removes the stream before it closes the fd.
        if stream.fd >= 0 { shutdown(stream.fd, SHUT_RDWR) }
        lock.unlock()
        stream.socket.close(code: code)
    }

    static func writeAll(_ fd: Int32, _ data: Data) async -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if (try? await Task.sleep(nanoseconds: 2_000_000)) == nil { return false }
                continue
            }
            return false
        }
        return true
    }
}

private final class RxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var received = false
    private let openLimit: TimeInterval
    private let steadyLimit: TimeInterval
    init(openLimit: TimeInterval, steadyLimit: TimeInterval) {
        self.openLimit = openLimit
        self.steadyLimit = steadyLimit
    }
    /// Before the first message the limit is `openLimit`; afterwards `steadyLimit` of silence is dead.
    func touch() { lock.lock(); last = Date(); received = true; lock.unlock() }
    var expired: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last) > (received ? steadyLimit : openLimit)
    }
}

private final class ByteCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var toMacValue: Int64 = 0
    private var fromMacValue: Int64 = 0
    private var pending = 0
    private var endedValue = false
    func markEnded() { lock.lock(); endedValue = true; lock.unlock() }
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return endedValue }
    func addToMac(_ n: Int) { lock.lock(); toMacValue += Int64(n); lock.unlock() }
    func addPending(_ n: Int) { lock.lock(); pending += n; lock.unlock() }
    func sentFromMac(_ n: Int) { lock.lock(); pending -= n; fromMacValue += Int64(n); lock.unlock() }
    var pendingOutbound: Int { lock.lock(); defer { lock.unlock() }; return pending }
    var toMac: Int64 { lock.lock(); defer { lock.unlock() }; return toMacValue }
    var fromMac: Int64 { lock.lock(); defer { lock.unlock() }; return fromMacValue }
}

private final class LiveCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func decrement() -> Int { lock.lock(); defer { lock.unlock() }; value -= 1; return value }
}
