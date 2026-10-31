import XCTest
import Darwin
@testable import SocketServer

final class LoopbackHTTPBoundsTests: XCTestCase {
    private func read(_ request: String, cap: Int = 8) throws -> LoopbackHTTPListener.ReadOutcome {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let bytes = Array(request.utf8)
        let client = pair[1]
        let written = expectation(description: "socket request written")
        DispatchQueue.global().async {
            bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard count > 0 else { break }
                    offset += count
                }
                XCTAssertEqual(offset, buffer.count)
            }
            shutdown(client, SHUT_WR)
            written.fulfill()
        }
        let result = LoopbackHTTPListener.readRequest(fd: pair[0], deadline: Date().addingTimeInterval(2), maxBodyBytes: cap)
        wait(for: [written], timeout: 2)
        return result
    }

    func testTerminatorInSecondReceiveCannotBypassHeaderLimit() throws {
        let request = "GET / HTTP/1.1\r\nX-Fill: " + String(repeating: "a", count: LoopbackHTTPListener.maxHeaderBytes) + "\r\n\r\n"
        guard case .reject(431) = try read(request) else { return XCTFail("Oversized headers must fail even when the separator arrives in the next read") }
    }

    func testDeclaredBodyOverCapIsRejected() throws {
        guard case .reject(413) = try read("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\n123456789") else { return XCTFail("Declared size must be checked before body acceptance") }
    }

    func testTrailingBodyIsRejectedAndExactBodyStillReachesHandler() throws {
        guard case .reject(400) = try read("POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\n" + String(repeating: "a", count: 10_000)) else { return XCTFail("Trailing bytes must not be accepted as a second request or appended to the body") }
        guard case .request(let value) = try read("POST / HTTP/1.1\r\nContent-Length: 8\r\n\r\n12345678") else { return XCTFail("The exact configured body limit remains valid") }
        XCTAssertEqual(value.body, Data("12345678".utf8))
    }
}
