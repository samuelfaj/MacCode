import Foundation

/// Framing for relay mux v1. The host frames travel on the Mac's `/v1/host`
/// socket and carry every phone session; the inner frames travel inside one
/// Noise session and carry every TCP connection of the phone.
public enum RelayMux {
    public static let hostHeader = "X-RC-Relay-Mux"
    public static let connectQueryItem = URLQueryItem(name: "mux", value: "1")
    /// Relay close code: the phone asked for inner mux but the Mac does not speak it.
    public static let unsupportedCloseCode = 4409
    public static let maxInnerStreams = 256
    /// Largest inner DATA payload that still fits one Noise transport message.
    public static let maxInnerPayload = RelayNoise.maxPlaintextChunk - 5

    public enum HostFrame: Equatable, Sendable {
        case open(session: UUID, innerMux: Bool)
        case data(session: UUID, payload: Data)
        case close(session: UUID, code: UInt16)
    }

    public enum InnerFrame: Equatable, Sendable {
        case open(stream: UInt32)
        case data(stream: UInt32, payload: Data)
        case close(stream: UInt32)
    }

    private static let typeOpen: UInt8 = 1
    private static let typeData: UInt8 = 2
    private static let typeClose: UInt8 = 3

    public static func encode(_ frame: HostFrame) -> Data {
        var out = Data()
        switch frame {
        case .open(let session, let innerMux):
            out.reserveCapacity(18)
            out.append(typeOpen)
            append(session, to: &out)
            out.append(innerMux ? 1 : 0)
        case .data(let session, let payload):
            out.reserveCapacity(17 + payload.count)
            out.append(typeData)
            append(session, to: &out)
            out.append(payload)
        case .close(let session, let code):
            out.reserveCapacity(19)
            out.append(typeClose)
            append(session, to: &out)
            out.append(UInt8(code >> 8))
            out.append(UInt8(code & 0xFF))
        }
        return out
    }

    /// nil for a frame this version does not understand; callers ignore it.
    public static func decodeHost(_ data: Data) -> HostFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 17 else { return nil }
        let session = uuid(bytes, at: 1)
        switch bytes[0] {
        case typeOpen:
            guard bytes.count == 18 else { return nil }
            return .open(session: session, innerMux: bytes[17] & 1 == 1)
        case typeData:
            guard bytes.count > 17 else { return nil }
            return .data(session: session, payload: Data(bytes[17...]))
        case typeClose:
            guard bytes.count == 19 else { return nil }
            return .close(session: session, code: UInt16(bytes[17]) << 8 | UInt16(bytes[18]))
        default:
            return nil
        }
    }

    public static func encode(_ frame: InnerFrame) -> Data {
        var out = Data()
        switch frame {
        case .open(let stream):
            out.append(typeOpen)
            append(stream, to: &out)
        case .data(let stream, let payload):
            out.reserveCapacity(5 + payload.count)
            out.append(typeData)
            append(stream, to: &out)
            out.append(payload)
        case .close(let stream):
            out.append(typeClose)
            append(stream, to: &out)
        }
        return out
    }

    public static func decodeInner(_ data: Data) -> InnerFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }
        let stream = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        switch bytes[0] {
        case typeOpen: return bytes.count == 5 ? .open(stream: stream) : nil
        case typeData: return bytes.count > 5 ? .data(stream: stream, payload: Data(bytes[5...])) : nil
        case typeClose: return bytes.count == 5 ? .close(stream: stream) : nil
        default: return nil
        }
    }

    /// Splits a byte run into DATA frames that each fit one Noise message.
    public static func innerDataFrames(stream: UInt32, bytes: Data) -> [Data] {
        guard !bytes.isEmpty else { return [] }
        var frames: [Data] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + maxInnerPayload, bytes.endIndex)
            frames.append(encode(.data(stream: stream, payload: Data(bytes[offset..<end]))))
            offset = end
        }
        return frames
    }

    /// Relay text control frame, or nil when the text is something else.
    public enum Control: Equatable, Sendable {
        /// Host socket: the relay routes sessions through mux frames.
        case hello(mux: Int)
        /// Phone socket: whether the Mac accepted inner mux for this session.
        case mux(ok: Bool)
    }

    public static func control(_ text: String) -> Control? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "hello": return .hello(mux: object["mux"] as? Int ?? 0)
        case "mux": return .mux(ok: object["ok"] as? Bool ?? false)
        default: return nil
        }
    }

    private static func append(_ id: UUID, to out: inout Data) {
        withUnsafeBytes(of: id.uuid) { out.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to out: inout Data) {
        out.append(UInt8(value >> 24))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func uuid(_ bytes: [UInt8], at offset: Int) -> UUID {
        let b = Array(bytes[offset..<(offset + 16)])
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
