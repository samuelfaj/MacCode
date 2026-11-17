import Foundation
import XCTest
@testable import CoreModel

final class DesktopToolsTests: XCTestCase {
    func testDesktopCaptureTimeoutReleasesCallerWhenCaptureStalls() async {
        let started = Date()
        let result = await DesktopToolsBackend.boundedDesktopCapture(seconds: 0.01) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return ComputerUseToolResult(text: "late image")
        }
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("desktop_capture_timeout") == true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testEveryToolHasDescriptionAndObjectSchema() throws {
        let tools = DesktopToolsBackend.observationTools + DesktopToolsBackend.mutationTools
        XCTAssertEqual(Set(tools).count, 14)
        for tool in tools {
            XCTAssertFalse(try XCTUnwrap(DesktopToolsBackend.description(for: tool)).isEmpty, tool)
            let schema = try XCTUnwrap(DesktopToolsBackend.inputSchema(for: tool))
            XCTAssertEqual(schema["type"] as? String, "object", tool)
            XCTAssertNotNil(schema["properties"], tool)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(schema), tool)
        }
        XCTAssertNil(DesktopToolsBackend.inputSchema(for: "missing"))
        XCTAssertNil(DesktopToolsBackend.description(for: "missing"))
    }

    func testValidationRejectsInvalidArgumentsBeforeDesktopAccess() {
        let invalid: [(String, [String: Any])] = [
            ("kill_app", [:]), ("kill_app", ["pid": 0]), ("kill_app", ["pid": true]),
            ("kill_app", ["pid": 1.5]), ("kill_app", ["pid": Int64(Int32.max) + 1]),
            ("bring_to_front", ["pid": 1, "window_id": 0]),
            ("set_window_frame", ["pid": 1, "window_id": 1, "x": 0, "y": 0, "width": 0, "height": 10]),
            ("set_window_frame", ["pid": 1, "window_id": 1, "x": Double.nan, "y": 0, "width": 10, "height": 10]),
            ("launch_app", [:]), ("launch_app", ["name": " "]),
            ("launch_app", ["name": "Finder", "bundle_id": "com.apple.finder"]),
            ("launch_app", ["name": "Finder", "urls": ["relative"]]),
            ("launch_app", ["name": "Finder", "additional_arguments": [1]]),
            ("clipboard_read", ["include_text": 1]), ("check_permissions", ["prompt": "true"]),
            ("set_config", ["max_image_dimension": -1]), ("set_config", ["max_image_dimension": 1.5]),
            ("set_config", ["max_image_dimension": true]), ("get_config", ["unexpected": true])
        ]
        for (name, arguments) in invalid {
            XCTAssertNotNil(DesktopToolsBackend.validationError(name: name, arguments: arguments), "\(name): \(arguments)")
        }
        XCTAssertNil(DesktopToolsBackend.validationError(name: "launch_app", arguments: ["name": "Finder", "urls": ["file:///tmp/example"], "creates_new_application_instance": false]))
        XCTAssertNil(DesktopToolsBackend.validationError(name: "set_window_frame", arguments: ["pid": 1, "window_id": 1, "x": -100, "y": 0, "width": 10, "height": 10]))
        XCTAssertNil(DesktopToolsBackend.validationError(name: "clipboard_read", arguments: [:]))
    }

    func testClipboardRejectsAmbiguousRelativeAndSymlinkInputs() throws {
        for arguments: [String: Any] in [[:], ["text": "hello", "image_path": "/image.png"], ["image_path": "/image.png", "file_path": "/file"], ["file_path": "relative"], ["image_path": "~/image.png"]] {
            XCTAssertNotNil(DesktopToolsBackend.validationError(name: "clipboard_write", arguments: arguments))
        }
        XCTAssertNil(DesktopToolsBackend.validationError(name: "clipboard_write", arguments: ["text": ""]))
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data("hello".utf8).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(DesktopToolsBackend.validationError(name: "clipboard_write", arguments: ["file_path": file.path]))
        XCTAssertNotNil(DesktopToolsBackend.validationError(name: "clipboard_write", arguments: ["file_path": link.path]))
        let parentLink = directory.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: directory)
        XCTAssertNotNil(DesktopToolsBackend.validationError(name: "clipboard_write", arguments: ["file_path": parentLink.appendingPathComponent("file").path]))
    }

    func testConfigRoundTripPersistsAndInvalidUpdatePreservesValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nested/config.json")
        let backend = DesktopToolsBackend(configURL: path)
        let initial = await backend.invoke(name: "get_config", arguments: [:])
        XCTAssertEqual(try object(initial)["max_image_dimension"] as? Int, 0)
        for dimension in [1024, 0] {
            let result = await backend.invoke(name: "set_config", arguments: ["max_image_dimension": dimension])
            XCTAssertFalse(result.isError)
            let read = await DesktopToolsBackend(configURL: path).invoke(name: "get_config", arguments: [:])
            XCTAssertEqual(try object(read)["max_image_dimension"] as? Int, dimension)
        }
        let invalid = await backend.invoke(name: "set_config", arguments: ["max_image_dimension": -1])
        XCTAssertTrue(invalid.isError)
        let read = await backend.invoke(name: "get_config", arguments: [:])
        XCTAssertEqual(try object(read)["max_image_dimension"] as? Int, 0)
        try Data("not json".utf8).write(to: path)
        let corrupt = await backend.invoke(name: "set_config", arguments: ["max_image_dimension": 200])
        XCTAssertTrue(corrupt.isError)
        XCTAssertEqual(try String(contentsOf: path), "not json", "Do not overwrite malformed user configuration")
    }

    private func object(_ result: ComputerUseToolResult) throws -> [String: Any] {
        let text = try XCTUnwrap(result.content.first?.text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
