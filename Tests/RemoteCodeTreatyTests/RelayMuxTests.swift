import XCTest
@testable import RemoteCodeTreaty

final class RelayMuxTests: XCTestCase {
    // The relay (TypeScript) parses these exact bytes; a layout change breaks every Mac in the field.
    func testHostFrameLayoutMatchesRelaySpec() {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let idBytes: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        XCTAssertEqual([UInt8](RelayMux.encode(.open(session: id, innerMux: true))), [1] + idBytes + [1])
        XCTAssertEqual([UInt8](RelayMux.encode(.data(session: id, payload: Data([9, 8])))), [2] + idBytes + [9, 8])
        XCTAssertEqual([UInt8](RelayMux.encode(.close(session: id, code: 4503))), [3] + idBytes + [0x11, 0x97])
    }

    func testHostFramesRoundTripAndRejectMalformed() {
        let id = UUID()
        for frame in [RelayMux.HostFrame.open(session: id, innerMux: false),
                      .data(session: id, payload: Data([1, 2, 3])),
                      .close(session: id, code: 1000)] {
            XCTAssertEqual(RelayMux.decodeHost(RelayMux.encode(frame)), frame)
        }
        XCTAssertNil(RelayMux.decodeHost(Data([2] + [UInt8](repeating: 0, count: 16))), "DATA needs a payload")
        XCTAssertNil(RelayMux.decodeHost(Data([9] + [UInt8](repeating: 0, count: 17))), "unknown type is ignored")
        XCTAssertNil(RelayMux.decodeHost(Data([3, 0, 0])))
    }

    func testInnerFramesRoundTripBigEndianStreamId() {
        XCTAssertEqual([UInt8](RelayMux.encode(.open(stream: 0x01020304))), [1, 1, 2, 3, 4])
        for frame in [RelayMux.InnerFrame.open(stream: 7), .data(stream: 7, payload: Data([5])), .close(stream: 7)] {
            XCTAssertEqual(RelayMux.decodeInner(RelayMux.encode(frame)), frame)
        }
        XCTAssertNil(RelayMux.decodeInner(Data([2, 0, 0, 0, 1])), "DATA needs a payload")
    }

    // Each inner frame must fit one Noise transport message or the channel rejects it.
    func testInnerDataFramesFitOneNoiseMessage() {
        let bytes = Data(repeating: 7, count: RelayMux.maxInnerPayload * 2 + 3)
        let frames = RelayMux.innerDataFrames(stream: 1, bytes: bytes)
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.count <= RelayNoise.maxPlaintextChunk })
        let joined = frames.compactMap { frame -> Data? in
            if case .data(_, let payload) = RelayMux.decodeInner(frame) { return payload }
            return nil
        }.reduce(Data(), +)
        XCTAssertEqual(joined, bytes)
    }

    func testControlFrames() {
        XCTAssertEqual(RelayMux.control(#"{"type":"hello","mux":1}"#), .hello(mux: 1))
        XCTAssertEqual(RelayMux.control(#"{"type":"mux","ok":false}"#), .mux(ok: false))
        XCTAssertNil(RelayMux.control(#"{"type":"pong"}"#))
    }
}
