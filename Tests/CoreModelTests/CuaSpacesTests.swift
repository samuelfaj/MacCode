import Foundation
import XCTest
@testable import CoreModel

final class CuaSpacesTests: XCTestCase {
    private func fakeCLI() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("cua").path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    func testMissingCLIReportsUnavailableWithoutRunningAnything() {
        let spaces = CuaSpaces(environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"]) { _, _ in
            XCTFail("Nothing should run when cua is absent"); return nil
        }
        XCTAssertEqual(spaces.status()["available"] as? Bool, false)
    }

    func testListsSpacesWithGuidanceWhenCLIWorks() throws {
        let cli = try fakeCLI()
        let spaces = CuaSpaces(environment: ["CUA_BIN": cli]) { executable, arguments in
            XCTAssertEqual(executable, cli)
            XCTAssertEqual(arguments, ["--json", "spaces", "ls"])
            return (0, Data(#"{"relay_error":null,"spaces":[{"name":"dev"}]}"#.utf8))
        }
        let status = spaces.status()
        XCTAssertEqual(status["available"] as? Bool, true)
        XCTAssertEqual((status["spaces"] as? [[String: Any]])?.first?["name"] as? String, "dev")
        XCTAssertNotNil(status["guidance"])
    }

    func testFailingCLIIsNotReportedAsAvailable() throws {
        let cli = try fakeCLI()
        let spaces = CuaSpaces(environment: ["CUA_BIN": cli]) { _, _ in (1, Data("not json".utf8)) }
        XCTAssertEqual(spaces.status()["available"] as? Bool, false)
    }

    func testMCPCuaStatusIsReadOnlyAndAdvertised() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-tests-\(UUID().uuidString)/computer-use.lock")
        let handler = ManagedComputerUseMCP(
            queue: ComputerUseHostQueue(lockURL: lock),
            backend: ComputerUseQueuedPassthroughBackend(),
            cua: CuaSpaces(environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"])
        )
        XCTAssertTrue(ManagedComputerUseMCP.observationTools.contains("cua_status"))
        let reply = await handler.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"cua_status","arguments":{}}}"#)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(reply).utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertFalse(text.contains("queued"), "cua_status must not reach the native backend")
        XCTAssertTrue(text.contains(#""available":false"#))
    }
}
