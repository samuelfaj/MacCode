import Darwin
import Foundation
import RemoteCodeTreaty

/// One phone session carried as DATA/CLOSE frames on the Mac's host socket.
/// It looks like a relay WebSocket to `RelaySecureChannel`.
final class RelayVirtualSocket: RelayWebSocket, @unchecked Sendable {
    let id: UUID
    private let host: RelayWebSocket
    private let lock = NSLock()
    private var queue: [Data] = []
    private var waiters: [CheckedContinuation<RelayMessage, Error>] = []
    private var closed = false

    init(id: UUID, host: RelayWebSocket) {
        self.id = id
        self.host = host
    }

    var isClosed: Bool { lock.withLock { closed } }

    func deliver(_ payload: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<RelayMessage, Error>? in
            guard !closed else { return nil }
            if waiters.isEmpty { queue.append(payload); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: .binary(payload))
    }

    /// The relay or the host socket ended this session; nothing is sent back.
    func remoteClosed() {
        let pending = lock.withLock { () -> [CheckedContinuation<RelayMessage, Error>] in
            closed = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume(throwing: URLError(.networkConnectionLost)) }
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw URLError(.networkConnectionLost) }
        try await host.send(RelayMux.encode(.data(session: id, payload: data)))
    }

    func sendText(_ text: String) async throws {
        throw RelayChannelError.unexpectedTextFrame
    }

    func receiveMessage() async throws -> RelayMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let payload = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: .binary(payload))
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func close(code: Int) {
        guard lock.withLock({ () -> Bool in
            defer { closed = true }
            return !closed
        }) else { return }
        remoteClosed()
        let host = self.host
        let frame = RelayMux.encode(.close(session: id, code: UInt16(clamping: code)))
        Task { try? await host.send(frame) }
    }
}

/// Splits one Noise session into many HTTP connections to the local server.
/// Every inner stream gets its own socketpair, exactly like a legacy relay stream.
final class RelayInnerMuxBridge: @unchecked Sendable {
    private final class Inner: @unchecked Sendable {
        let fd: Int32
        let inbound: AsyncStream<Data>.Continuation
        private let lock = NSLock()
        private var endedValue = false
        private var live = 2
        init(fd: Int32, inbound: AsyncStream<Data>.Continuation) {
            self.fd = fd
            self.inbound = inbound
        }
        var ended: Bool { lock.withLock { endedValue } }
        /// True only the first time.
        func markEnded() -> Bool { lock.withLock { defer { endedValue = true }; return !endedValue } }
        /// True when both the reader and the writer finished; then the fd may be closed.
        func release() -> Bool { lock.withLock { live -= 1; return live == 0 } }
    }

    private let channel: RelaySecureChannel
    private let server: DirectHTTPServer
    private let peer: String
    private let lock = NSLock()
    private var inners: [UInt32: Inner] = [:]
    private var usedIds = Set<UInt32>()
    private var pendingOutbound = 0
    private let outbound: AsyncStream<Data>
    private let outboundSink: AsyncStream<Data>.Continuation

    init(channel: RelaySecureChannel, server: DirectHTTPServer, peer: String) {
        self.channel = channel
        self.server = server
        self.peer = peer
        (outbound, outboundSink) = AsyncStream.makeStream(of: Data.self)
    }

    /// Returns when the session ends; every inner connection is closed by then.
    func run() async {
        // One writer keeps the Noise nonce order equal to the send order.
        let writer = Task { [channel, outbound] in
            for await frame in outbound {
                do { try await channel.send(frame) } catch { break }
                self.lock.withLock { self.pendingOutbound -= frame.count }
            }
            channel.close(code: 1000)
        }
        receive: while let plaintext = try? await channel.receive() {
            guard let frame = RelayMux.decodeInner(plaintext) else { continue }
            switch frame {
            case .open(let id):
                guard open(id) else {
                    channel.close(code: 4400)
                    break receive
                }
            case .data(let id, let payload):
                lock.withLock { inners[id] }?.inbound.yield(payload)
            case .close(let id):
                lock.withLock { inners[id] }?.inbound.finish()
            }
        }
        let open = lock.withLock { Array(inners.values) }
        for inner in open { end(inner, notify: false) }
        outboundSink.finish()
        writer.cancel()
        await writer.value
    }

    private var backlog: Int { lock.withLock { pendingOutbound } }

    private func enqueue(_ frame: Data) {
        lock.withLock { pendingOutbound += frame.count }
        outboundSink.yield(frame)
    }

    /// False for a reused id, which is a protocol violation.
    private func open(_ id: UInt32) -> Bool {
        let accepted = lock.withLock { () -> Bool? in
            guard usedIds.insert(id).inserted else { return nil }
            return inners.count < RelayMux.maxInnerStreams
        }
        guard let accepted else { return false }
        guard accepted else {
            enqueue(RelayMux.encode(.close(stream: id)))
            return true
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            enqueue(RelayMux.encode(.close(stream: id)))
            return true
        }
        let (a, b) = (pair[0], pair[1])
        var yes: Int32 = 1
        for fd in [a, b] {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            DirectHTTPServer.enableCloseOnExec(fd)
        }
        guard server.registerRelayConnection(fd: a) else {
            Darwin.close(a)
            Darwin.close(b)
            enqueue(RelayMux.encode(.close(stream: id)))
            return true
        }
        _ = fcntl(b, F_SETFL, fcntl(b, F_GETFL) | O_NONBLOCK)
        let (inbound, inboundSink) = AsyncStream.makeStream(of: Data.self)
        let inner = Inner(fd: b, inbound: inboundSink)
        lock.withLock { inners[id] = inner }
        let server = self.server, peer = self.peer
        Thread.detachNewThread { server.serveRelayConnection(fd: a, peer: peer) }

        // iPhone -> Mac: in order, never blocking the session receive loop.
        Task { [weak self] in
            var delivered = true
            for await chunk in inbound {
                if await !RelayHostClient.writeAll(b, chunk) { delivered = false; break }
            }
            // A phone CLOSE needs no answer; a local write failure must reach the phone.
            self?.end(inner, id: id, notify: !delivered)
            if inner.release() { Darwin.close(b) }
        }
        // Mac -> iPhone
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: RelayMux.maxInnerPayload)
            while !inner.ended {
                if (self?.backlog ?? 0) > 4 * 1_048_576 {
                    usleep(5_000)
                    continue
                }
                var pfd = pollfd(fd: b, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 500)
                if ready < 0, errno == EINTR { continue }
                if ready < 0 { break }
                if ready == 0 { continue }
                let n = read(b, &buffer, buffer.count)
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                if n <= 0 { break }
                self?.enqueue(RelayMux.encode(.data(stream: id, payload: Data(buffer[0..<n]))))
            }
            self?.end(inner, id: id, notify: true)
            if inner.release() { Darwin.close(b) }
        }
        return true
    }

    private func end(_ inner: Inner, id: UInt32? = nil, notify: Bool) {
        guard inner.markEnded() else { return }
        if let id {
            lock.withLock { if inners[id] === inner { inners[id] = nil } }
            if notify { enqueue(RelayMux.encode(.close(stream: id))) }
        }
        shutdown(inner.fd, SHUT_RDWR)
        inner.inbound.finish()
    }
}
