import Darwin
import Foundation

/// One HTTP/1.1 request read by `LoopbackHTTPListener`. Header names are lowercased.
public struct LoopbackHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public struct LoopbackHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ body: Data, status: Int = 200) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

/// A minimal HTTP/1.1 server bound to IPv4 127.0.0.1 on a kernel-chosen port.
///
/// One request per connection (`Connection: close`), `Content-Length` bodies
/// only. Every connection gets its own thread and the handler runs on that
/// thread, so blocking handlers never touch Swift's cooperative pool. The
/// handler also receives a probe that reports whether the client hung up, and
/// may return nil to close the connection without a response.
public final class LoopbackHTTPListener: @unchecked Sendable {
    public typealias Handler = @Sendable (
        _ request: LoopbackHTTPRequest,
        _ isClientGone: @escaping @Sendable () -> Bool
    ) -> LoopbackHTTPResponse?

    public let maxConnections: Int
    public let maxBodyBytes: Int
    public let headerTimeout: TimeInterval
    static let maxHeaderBytes = 16 * 1_024

    private let name: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPort: UInt16?
    private var generation: UInt64 = 0
    private var connections: Set<Int32> = []

    public init(
        name: String,
        maxConnections: Int = 32,
        maxBodyBytes: Int = 1_024 * 1_024,
        headerTimeout: TimeInterval = 30,
        handler: @escaping Handler
    ) {
        self.name = name
        self.maxConnections = maxConnections
        self.maxBodyBytes = maxBodyBytes
        self.headerTimeout = headerTimeout
        self.handler = handler
    }

    deinit { stop() }

    /// Binds on first call; later calls return the same port.
    @discardableResult
    public func start() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if let boundPort { return boundPort }
        let fd = try Self.bindIPv4Loopback()
        let port: UInt16
        do {
            port = try Self.port(of: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        generation &+= 1
        listenFD = fd
        boundPort = port
        let current = generation
        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd, generation: current) }
        thread.name = "\(name).accept"
        thread.start()
        return port
    }

    /// Closes the listening socket and every open connection. `start()` binds a new port.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        boundPort = nil
        // Shut down only: the connection thread owns the descriptor and closes it.
        for fd in connections { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    public var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    // MARK: - Accept and serve

    private func acceptLoop(fd: Int32, generation: UInt64) {
        while isCurrent(generation) {
            let accepted = Darwin.accept(fd, nil, nil)
            if accepted < 0 {
                if !isCurrent(generation) { return }
                continue
            }
            guard DirectHTTPServer.enableCloseOnExec(accepted) else {
                Darwin.close(accepted)
                continue
            }
            var yes: Int32 = 1
            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(accepted, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            guard register(accepted, generation: generation) else {
                Self.write(LoopbackHTTPResponse(status: 503), to: accepted)
                Darwin.close(accepted)
                continue
            }
            let thread = Thread { [weak self] in
                self?.serve(fd: accepted)
                self?.unregister(accepted)
                Darwin.close(accepted)
            }
            thread.name = "\(name).conn"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.generation == generation
    }

    private func register(_ fd: Int32, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation, connections.count < maxConnections else { return false }
        connections.insert(fd)
        return true
    }

    private func unregister(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        connections.remove(fd)
    }

    private func serve(fd: Int32) {
        let response: LoopbackHTTPResponse?
        switch Self.readRequest(fd: fd, deadline: Date().addingTimeInterval(headerTimeout), maxBodyBytes: maxBodyBytes) {
        case .request(let request):
            response = handler(request, { Self.isClientGone(fd: fd) })
        case .reject(let status):
            response = LoopbackHTTPResponse(status: status)
        case .closed:
            response = nil
        }
        if let response { Self.write(response, to: fd) }
    }

    enum ReadOutcome {
        case request(LoopbackHTTPRequest)
        case reject(Int)
        case closed
    }

    static func readRequest(fd: Int32, deadline: Date, maxBodyBytes: Int) -> ReadOutcome {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            guard buffer.count <= maxHeaderBytes else { return .reject(431) }
            guard let chunk = receive(fd: fd, deadline: deadline) else { return .closed }
            buffer.append(chunk)
            headEnd = buffer.range(of: separator)
        }
        if let headEnd, headEnd.lowerBound > maxHeaderBytes { return .reject(431) }
        guard let headEnd,
              let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return .reject(400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .reject(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { return .reject(400) }
            headers[key] = value
        }
        if headers["transfer-encoding"] != nil { return .reject(411) }
        var length = 0
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { return .reject(400) }
            length = parsed
        } else if requestLine[0] == "POST" {
            return .reject(411)
        }
        guard length <= maxBodyBytes else { return .reject(413) }
        guard buffer.count - headEnd.upperBound <= length else { return .reject(400) }
        var body = Data(buffer[headEnd.upperBound...])
        while body.count < length {
            guard let chunk = receive(fd: fd, deadline: deadline) else { return .closed }
            guard chunk.count <= length - body.count else { return .reject(400) }
            body.append(chunk)
        }
        guard body.count == length else { return .reject(400) }
        return .request(LoopbackHTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: body
        ))
    }

    private static func receive(fd: Int32, deadline: Date) -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32(min(remaining * 1_000, Double(Int32.max)))) > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        let count = Darwin.recv(fd, &bytes, bytes.count, 0)
        guard count > 0 else { return nil }
        return Data(bytes[0..<count])
    }

    /// True once the client closed or reset its end while the handler works.
    static func isClientGone(fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, 0)
        if ready < 0 { return true }
        if ready == 0 { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        let peeked = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    static func write(_ response: LoopbackHTTPResponse, to fd: Int32) {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (key, value) in response.headers.sorted(by: { $0.key < $1.key })
        where key.lowercased() != "content-length" && key.lowercased() != "connection" {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    // MARK: - Socket setup

    private static func bindIPv4Loopback() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard DirectHTTPServer.enableCloseOnExec(fd) else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, Darwin.listen(fd, 32) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(fd)
            throw POSIXError(code)
        }
        return fd
    }

    private static func port(of fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard result == 0, port > 0 else { throw POSIXError(.EIO) }
        return port
    }

#if DEBUG
    var boundAddressForTesting: String? {
        lock.lock(); defer { lock.unlock() }
        guard listenFD >= 0 else { return nil }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return String(cString: inet_ntoa(address.sin_addr))
    }
#endif
}
