import CryptoKit
import Foundation

public enum RelayMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

public protocol RelayWebSocket: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func sendText(_ text: String) async throws
    func receiveMessage() async throws -> RelayMessage
    func close(code: Int)
}

/// A relay socket that can report the HTTP status the relay answered the upgrade with.
public protocol RelayHTTPStatusReporting: AnyObject {
    /// nil until the relay answered; 101 after a successful upgrade.
    var upgradeHTTPStatus: Int? { get }
}

public enum RelayChannelError: Error, Equatable {
    case unexpectedTextFrame, untrustedKey, handshakeTimedOut
}

public extension RelayWebSocket {
    /// Binary frames only; a text frame is a protocol violation.
    func receive() async throws -> Data {
        switch try await receiveMessage() {
        case .binary(let data): return data
        case .text: throw RelayChannelError.unexpectedTextFrame
        }
    }
}

public final class URLSessionRelayWebSocket: RelayWebSocket, RelayHTTPStatusReporting, @unchecked Sendable {
    public static let maximumMessageSize = 1_048_576 + 64
    private let task: URLSessionWebSocketTask

    public init(_ request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
    }

    public var upgradeHTTPStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receiveMessage() async throws -> RelayMessage {
        switch try await task.receive() {
        case .data(let data): return .binary(data)
        case .string(let text): return .text(text)
        @unknown default: throw RelayChannelError.unexpectedTextFrame
        }
    }

    public func close(code: Int) {
        task.cancel(
            with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
            reason: nil
        )
    }
}

public enum RelayEndpoints {
    public static func host(base: URL, serverId: String) -> URL {
        url(base, path: "/v1/host", serverId: serverId)
    }

    public static func connect(base: URL, serverId: String) -> URL {
        url(base, path: "/v1/connect", serverId: serverId)
    }

    public static func stream(base: URL, serverId: String, streamId: String) -> URL {
        url(base, path: "/v1/stream/" + streamId, serverId: serverId)
    }

    private static func url(_ base: URL, path: String, serverId: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.percentEncodedPath = prefix + path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed
        )!
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        components.percentEncodedQuery = "server_id="
            + (serverId.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        return components.url ?? base
    }
}

/// One per relay stream. Sends are expected from a single task; receives from a single task.
public final class RelaySecureChannel: @unchecked Sendable {
    private let socket: RelayWebSocket
    private let transport: RelayNoiseTransport
    private let sendLock = NSLock()

    private init(socket: RelayWebSocket, transport: RelayNoiseTransport) {
        self.socket = socket
        self.transport = transport
    }

    /// iPhone side: write message 1, read message 2.
    public static func initiate(
        socket: RelayWebSocket,
        initiatorStatic: Curve25519.KeyAgreement.PrivateKey,
        responderStaticPublicKey: Data,
        serverId: String,
        timeout: TimeInterval = 10
    ) async throws -> RelaySecureChannel {
        try await withHandshakeDeadline(socket: socket, timeout: timeout) {
            do {
                let handshake = try RelayNoiseHandshake(
                    initiatorStatic: initiatorStatic,
                    responderStaticPublicKey: responderStaticPublicKey,
                    prologue: RelayNoise.prologue(serverId: serverId)
                )
                try await socket.send(handshake.writeMessage())
                _ = try handshake.readMessage(try await socket.receive())
                return RelaySecureChannel(socket: socket, transport: try handshake.split())
            } catch {
                socket.close(code: 4400)
                throw error
            }
        }
    }

    /// Mac side: read message 1, check the initiator key, write message 2.
    public static func respond(
        socket: RelayWebSocket,
        responderStatic: Curve25519.KeyAgreement.PrivateKey,
        serverId: String,
        timeout: TimeInterval = 10,
        isTrusted: (Data) -> Bool
    ) async throws -> (RelaySecureChannel, initiatorStaticPublicKey: Data) {
        try await withHandshakeDeadline(socket: socket, timeout: timeout) {
            let handshake = RelayNoiseHandshake(
                responderStatic: responderStatic,
                prologue: RelayNoise.prologue(serverId: serverId)
            )
            let remoteKey: Data
            do {
                _ = try handshake.readMessage(try await socket.receive())
                guard let key = handshake.remoteStaticPublicKey else { throw RelayNoiseError.wrongState }
                remoteKey = key
            } catch {
                socket.close(code: 4400)
                throw error
            }
            guard isTrusted(remoteKey) else {
                socket.close(code: 4401)
                throw RelayChannelError.untrustedKey
            }
            do {
                try await socket.send(handshake.writeMessage())
                return (RelaySecureChannel(socket: socket, transport: try handshake.split()), remoteKey)
            } catch {
                socket.close(code: 4400)
                throw error
            }
        }
    }

    /// Races the handshake against a deadline. On expiry the socket is closed, which fails the pending read or write.
    private static func withHandshakeDeadline<T: Sendable>(
        socket: RelayWebSocket,
        timeout: TimeInterval,
        _ body: () async throws -> T
    ) async throws -> T {
        let expired = ExpiryFlag()
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                expired.set()
                socket.close(code: 4400)
            }
            defer { group.cancelAll() }
            do {
                let value = try await body()
                guard !expired.isSet else { throw RelayChannelError.handshakeTimedOut }
                return value
            } catch {
                throw expired.isSet ? RelayChannelError.handshakeTimedOut : error
            }
        }
    }

    public func send(_ bytes: Data) async throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + RelayNoise.maxPlaintextChunk, bytes.count)
            let chunk = Data(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + end)])
            let frame: Data
            do {
                sendLock.lock()
                defer { sendLock.unlock() }
                frame = try transport.encrypt(chunk)
            } catch {
                socket.close(code: 4400)
                throw error
            }
            try await socket.send(frame)
            offset = end
        }
    }

    public func receive() async throws -> Data {
        let frame = try await socket.receive()
        do {
            return try transport.decrypt(frame)
        } catch {
            socket.close(code: 4400)
            throw error
        }
    }

    public func close(code: Int = 1000) {
        socket.close(code: code)
    }
}

private final class ExpiryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
