import XCTest
import CoreModel
import CryptoKit
import Foundation
@testable import SocketServer

final class WorkspaceFileServiceTests: XCTestCase {
    private var root: URL!
    private let service = WorkspaceFileService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-files-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FileEditSessionStore.shared.resetForTests()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testListReturnsRelativeParentPathInsideWorkspace() throws {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let listed = try service.list(root: root.path, path: "Sources")

        XCTAssertEqual(listed.objectValue?["parent_path"]?.stringValue, "",
                       "Files navigation must return workspace-relative parent paths so macOS and iOS do not navigate by absolute host paths")
    }

    func testListRelativePathsStayWorkspaceRelativeWhenTmpRootIsSymlinked() throws {
        let tmpRootPath = "/tmp/rc2-files-symlink-\(UUID().uuidString)"
        let tmpRoot = URL(fileURLWithPath: tmpRootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try "print(\"nested\")".write(to: tmpRoot.appendingPathComponent("src/nested.swift"), atomically: true, encoding: .utf8)

        let rootList = try service.list(root: tmpRootPath, path: nil)
        let rootEntries = try XCTUnwrap(rootList.objectValue?["entries"]?.arrayValue)
        let srcEntry = try XCTUnwrap(rootEntries.first { $0.objectValue?["name"]?.stringValue == "src" })
        XCTAssertEqual(srcEntry.objectValue?["relative_path"]?.stringValue, "src",
                       "Files rows must keep workspace-relative paths even when macOS reports /tmp children through /private/tmp")

        let srcList = try service.list(root: tmpRootPath, path: "src")
        XCTAssertEqual(srcList.objectValue?["relative_path"]?.stringValue, "src",
                       "expanded folders must round-trip the same workspace-relative path the UI sends back")
        XCTAssertEqual(srcList.objectValue?["parent_path"]?.stringValue, "",
                       "expanded folder breadcrumbs must not inherit /private/tmp path fragments")
        let srcEntries = try XCTUnwrap(srcList.objectValue?["entries"]?.arrayValue)
        let nested = try XCTUnwrap(srcEntries.first { $0.objectValue?["name"]?.stringValue == "nested.swift" })
        XCTAssertEqual(nested.objectValue?["relative_path"]?.stringValue, "src/nested.swift",
                       "nested file selection must open the intended file instead of a corrupted path such as rkspace/src/nested.swift")
    }

    func testSvgIsPreviewMediaNotEditableText() throws {
        let svg = root.appendingPathComponent("logo.svg")
        try "<svg><text>RemoteCode</text></svg>".write(to: svg, atomically: true, encoding: .utf8)

        let read = try service.read(root: root.path, path: "logo.svg")
        let identity = try XCTUnwrap(read.objectValue?["identity"]?.objectValue)

        XCTAssertEqual(identity["kind"]?.stringValue, "image",
                       "media extensions such as SVG must use pretty preview classification instead of becoming editable plain text")
        XCTAssertNil(read.objectValue?["content"]?.stringValue,
                     "known media binaries/text containers must not be decoded into the source editor by default")
    }

    func testUTF16TextWithoutBOMCanBeReadForEditing() throws {
        let file = root.appendingPathComponent("notes.txt")
        let text = "hello from utf16"
        try XCTUnwrap(text.data(using: .utf16LittleEndian)).write(to: file)

        let read = try service.read(root: root.path, path: "notes.txt")

        XCTAssertEqual(read.objectValue?["content"]?.stringValue, text,
                       "safe UTF-16 text without a BOM must still be readable/editable instead of being treated as unknown binary")
        XCTAssertEqual(read.objectValue?["encoding"]?.stringValue, "utf-16le")
    }

    func testUnknownBinaryIsNotDecodedAsText() throws {
        let file = root.appendingPathComponent("archive.bin")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00]).write(to: file)

        let read = try service.read(root: root.path, path: "archive.bin")
        let identity = try XCTUnwrap(read.objectValue?["identity"]?.objectValue)

        XCTAssertEqual(identity["kind"]?.stringValue, "binary")
        XCTAssertNil(read.objectValue?["content"]?.stringValue,
                     "unknown binary files must show metadata only; decoding arbitrary bytes can corrupt the reader and editor")
    }

    func testCreateRenameAndDeleteStayInsideWorkspaceForFilesSidebarActions() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)

        let created = try service.createFile(root: root.path, path: "Sources/NewFile.swift", content: "")
        let createdPath = try XCTUnwrap(created.objectValue?["relative_path"]?.stringValue)
        XCTAssertEqual(createdPath, "Sources/NewFile.swift",
                       "the Files sidebar add-file action must create the exact workspace-relative file the user requested")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(createdPath).path))

        let renamed = try service.rename(root: root.path, path: "Sources/NewFile.swift", newName: "Renamed.swift")
        XCTAssertEqual(renamed.objectValue?["relative_path"]?.stringValue, "Sources/Renamed.swift",
                       "rename must keep the file in its current directory instead of allowing path injection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/NewFile.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Renamed.swift").path))

        _ = try service.createFile(root: root.path, path: "Sources/DeleteMe.swift", content: "")
        let deleted = try service.delete(root: root.path, paths: ["Sources/Renamed.swift", "Sources/DeleteMe.swift"])
        XCTAssertEqual(deleted.objectValue?["deleted"]?.arrayValue?.compactMap(\.stringValue).sorted(),
                       ["Sources/DeleteMe.swift", "Sources/Renamed.swift"],
                       "multi-select delete must remove every selected workspace-relative file in one host operation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Renamed.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/DeleteMe.swift").path))
    }

    func testFilesSidebarMutationsRejectEscapingAndOverwritePaths() throws {
        try service.createFile(root: root.path, path: "keep.txt", content: "")

        XCTAssertThrowsError(try service.createFile(root: root.path, path: "../escape.txt", content: ""),
                             "add-file must not write outside the workspace root")
        XCTAssertThrowsError(try service.rename(root: root.path, path: "keep.txt", newName: "../escape.txt"),
                             "rename from the Files context menu must reject names that escape the current directory")
        XCTAssertThrowsError(try service.rename(root: root.path, path: "keep.txt", newName: "keep.txt"),
                             "rename must not overwrite an existing workspace path silently")
        XCTAssertThrowsError(try service.delete(root: root.path, paths: [""]),
                             "bulk delete must not allow deleting the workspace root")
    }

    func testMultiDeletePreflightsAllPathsBeforeRemovingAnyFile() throws {
        try service.createFile(root: root.path, path: "keep.txt", content: "")

        XCTAssertThrowsError(try service.delete(root: root.path, paths: ["keep.txt", ""]),
                             "multi-select delete must reject the whole request before deleting any selected file when one path is invalid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path),
                      "failed multi-select delete must not partially remove files before reporting a validation error")
    }

    func testMultiDeleteHandlesDuplicateAndNestedSelectionsWithoutFailingMidDelete() throws {
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nested".write(to: folder.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        let deleted = try service.delete(root: root.path, paths: ["Folder", "Folder/child.txt", "Folder/child.txt"])

        XCTAssertEqual(deleted.objectValue?["deleted"]?.arrayValue?.compactMap(\.stringValue),
                       ["Folder", "Folder/child.txt"],
                       "duplicate selections should be reported once while parent/child selections still complete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "deleting a selected parent and child together must not fail after removing the parent first")
    }

    func testListUsesExtensionClassificationAndDoesNotReadFileBytes() throws {
        // Write a .swift file that contains raw binary bytes so content-based
        // classification would disagree with the extension. Listing must return
        // the extension-derived kind ("code") and must NOT read the bytes -- which
        // is verified by confirming the kind matches the extension, not the content.
        let swiftFile = root.appendingPathComponent("Main.swift")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: swiftFile) // JPEG magic bytes

        let listed = try service.list(root: root.path, path: nil)
        let entries = try XCTUnwrap(listed.objectValue?["entries"]?.arrayValue)
        let entry = try XCTUnwrap(entries.first(where: { $0.objectValue?["name"]?.stringValue == "Main.swift" }))
        let identity = try XCTUnwrap(entry.objectValue?["identity"]?.objectValue)

        XCTAssertEqual(identity["kind"]?.stringValue, "code",
                       "listing must classify by extension only; reading file bytes in a directory listing is wasteful and must not occur")
        XCTAssertEqual(identity["language"]?.stringValue, "swift",
                       "language must be derived from the file extension without reading content")
    }

    func testListIdentitySchemaMatchesAllConsumerFields() throws {
        // FilesSurface consumes kind, mime, is_editable, editability_reason, language.
        // All must be present in listing entries so the sidebar can render without a
        // second round-trip to read the file.
        let file = root.appendingPathComponent("readme.md")
        try "# hello".write(to: file, atomically: true, encoding: .utf8)

        let listed = try service.list(root: root.path, path: nil)
        let entries = try XCTUnwrap(listed.objectValue?["entries"]?.arrayValue)
        let entry = try XCTUnwrap(entries.first(where: { $0.objectValue?["name"]?.stringValue == "readme.md" }))
        let identity = try XCTUnwrap(entry.objectValue?["identity"]?.objectValue)

        XCTAssertNotNil(identity["kind"]?.stringValue, "FilesSurface requires identity.kind in listing")
        XCTAssertNotNil(identity["mime"]?.stringValue, "FilesSurface requires identity.mime in listing")
        XCTAssertNotNil(identity["is_editable"], "FilesSurface requires identity.is_editable in listing")
        XCTAssertNotNil(identity["editability_reason"]?.stringValue, "FilesSurface requires identity.editability_reason in listing")
        // language is optional for md but the key must be present (null is valid)
        XCTAssertTrue(identity.keys.contains("language"), "FilesSurface reads identity.language; key must exist in listing entries")
    }

    func testEditSaveRejectsExternallyGrownFileBeforeReadingWholeFile() throws {
        let file = root.appendingPathComponent("notes.txt")
        try "small".write(to: file, atomically: true, encoding: .utf8)
        let opened = try FileEditSessionStore.shared.open(
            surfaceID: SurfaceID(),
            workspaceID: WorkspaceID(),
            root: root.path,
            path: "notes.txt"
        )
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        defer { _ = try? FileEditSessionStore.shared.close(sessionID: sessionID) }

        try Data(repeating: 0x61, count: WorkspaceFileLimits.editBytes + 1).write(to: file)

        XCTAssertThrowsError(try FileEditSessionStore.shared.save(sessionID: sessionID),
                             "save conflict checks must not read an externally-grown file without the edit size cap")
    }

    /// WHY: the editor sends minimal patches over the decoded text; saving must not turn CRLF into LF
    /// or drop the UTF-16 BOM, otherwise every save silently rewrites the whole file.
    func testSavePreservesCRLFLineEndingsAndUTF16BOM() throws {
        let crlf = root.appendingPathComponent("win.txt")
        try Data("one\r\ntwo\r\nthree".utf8).write(to: crlf)
        let utf16 = root.appendingPathComponent("wide.txt")
        var wide = Data([0xFF, 0xFE])
        wide.append("a\r\nb".data(using: .utf16LittleEndian)!)
        try wide.write(to: utf16)

        func editAndSave(_ name: String, location: Int, replacement: String) throws -> (encoding: String?, content: String?) {
            let opened = try FileEditSessionStore.shared.open(surfaceID: SurfaceID(), workspaceID: WorkspaceID(), root: root.path, path: name)
            let id = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
            defer { _ = try? FileEditSessionStore.shared.close(sessionID: id) }
            let revision = try XCTUnwrap(opened.objectValue?["draft_revision"]?.intValue)
            _ = try FileEditSessionStore.shared.applyPatch(sessionID: id, baseDraftRevision: revision, rangeLocation: location, rangeLength: 0, replacement: replacement, deviceID: "t")
            let saved = try FileEditSessionStore.shared.save(sessionID: id)
            return (saved.objectValue?["encoding"]?.stringValue, saved.objectValue?["content"]?.stringValue)
        }

        let a = try editAndSave("win.txt", location: 0, replacement: "X")
        XCTAssertEqual(a.encoding, "utf-8", "session payload reports the file encoding for the status bar")
        XCTAssertEqual(try Data(contentsOf: crlf), Data("Xone\r\ntwo\r\nthree".utf8), "CRLF endings must survive a save")
        let b = try editAndSave("wide.txt", location: 0, replacement: "X")
        XCTAssertEqual(b.encoding, "utf-16le")
        var expected = Data([0xFF, 0xFE])
        expected.append("Xa\r\nb".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try Data(contentsOf: utf16), expected, "the UTF-16LE BOM and CRLF must survive a save")
    }

    func testEditConflictSaveReleasesLockExactlyOnceBeforeConcurrentFollowUp() throws {
        let file = root.appendingPathComponent("conflict.txt")
        let concurrentFile = root.appendingPathComponent("concurrent.txt")
        try "base".write(to: file, atomically: true, encoding: .utf8)
        try "concurrent".write(to: concurrentFile, atomically: true, encoding: .utf8)
        let opened = try FileEditSessionStore.shared.open(
            surfaceID: SurfaceID(),
            workspaceID: WorkspaceID(),
            root: root.path,
            path: "conflict.txt"
        )
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        _ = try FileEditSessionStore.shared.applyPatch(
            sessionID: sessionID,
            baseDraftRevision: 1,
            rangeLocation: 0,
            rangeLength: 0,
            replacement: "draft ",
            deviceID: nil
        )
        try "external".write(to: file, atomically: true, encoding: .utf8)

        let clockEntered = DispatchSemaphore(value: 0)
        let releaseClock = DispatchSemaphore(value: 0)
        let concurrentOpenFinished = DispatchSemaphore(value: 0)
        let followUpFinished = DispatchSemaphore(value: 0)
        FileEditSessionStore.shared.setClockForTests {
            clockEntered.signal()
            _ = releaseClock.wait(timeout: .now() + 2)
            return Date()
        }

        let rootPath = root.path
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "files.edit.conflict",
                  event.payload.objectValue?["session_id"]?.stringValue == sessionID else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { concurrentOpenFinished.signal() }
                _ = try? FileEditSessionStore.shared.open(
                    surfaceID: SurfaceID(),
                    workspaceID: WorkspaceID(),
                    root: rootPath,
                    path: "concurrent.txt"
                )
            }
            XCTAssertEqual(
                clockEntered.wait(timeout: .now() + 1),
                .success,
                "the competing edit open must own the store lock before the conflict save unwinds"
            )
        }
        defer { EventBus.shared.unsubscribe(token) }

        XCTAssertThrowsError(
            try FileEditSessionStore.shared.save(sessionID: sessionID),
            "a disk conflict must fail without corrupting the shared edit-session lock"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            _ = FileEditSessionStore.shared.session(sessionID: sessionID)
            followUpFinished.signal()
        }

        let earlyFollowUp = followUpFinished.wait(timeout: .now() + 0.1)
        XCTAssertEqual(
            earlyFollowUp,
            .timedOut,
            "a conflict save must not unlock a critical section currently owned by another edit operation"
        )

        releaseClock.signal()
        XCTAssertEqual(concurrentOpenFinished.wait(timeout: .now() + 1), .success)
        if earlyFollowUp == .timedOut {
            XCTAssertEqual(followUpFinished.wait(timeout: .now() + 1), .success)
        }

        _ = try FileEditSessionStore.shared.discard(sessionID: sessionID)
        _ = try FileEditSessionStore.shared.close(sessionID: sessionID)
    }

    func testEditLifecyclePublishesEveryCorrelatedProducerEvent() throws {
        let file = root.appendingPathComponent("notes.txt")
        try "base".write(to: file, atomically: true, encoding: .utf8)
        let workspaceID = WorkspaceID()
        let surfaceID = SurfaceID()
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind.hasPrefix("files.edit.") { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        let successful = try FileEditSessionStore.shared.open(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            root: root.path,
            path: "notes.txt"
        )
        let successfulID = try XCTUnwrap(successful.objectValue?["session_id"]?.stringValue)
        _ = try FileEditSessionStore.shared.applyPatch(
            sessionID: successfulID,
            baseDraftRevision: 1,
            rangeLocation: 4,
            rangeLength: 0,
            replacement: " safe",
            deviceID: "test-device"
        )
        _ = try FileEditSessionStore.shared.save(sessionID: successfulID)
        _ = try FileEditSessionStore.shared.close(sessionID: successfulID)

        let conflicted = try FileEditSessionStore.shared.open(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            root: root.path,
            path: "notes.txt"
        )
        let conflictedID = try XCTUnwrap(conflicted.objectValue?["session_id"]?.stringValue)
        _ = try FileEditSessionStore.shared.applyPatch(
            sessionID: conflictedID,
            baseDraftRevision: 1,
            rangeLocation: 0,
            rangeLength: 0,
            replacement: "draft ",
            deviceID: nil
        )
        try "external".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FileEditSessionStore.shared.save(sessionID: conflictedID))
        _ = try FileEditSessionStore.shared.discard(sessionID: conflictedID)
        _ = try FileEditSessionStore.shared.close(sessionID: conflictedID)

        XCTAssertEqual(events.map(\.kind), [
            "files.edit.opened", "files.edit.patch_applied", "files.edit.saved", "files.edit.closed",
            "files.edit.opened", "files.edit.patch_applied", "files.edit.conflict", "files.edit.discarded", "files.edit.closed"
        ])
        for event in events {
            let payload = try XCTUnwrap(event.payload.objectValue)
            XCTAssertEqual(payload["workspace_id"], .string(workspaceID.value.uuidString))
            XCTAssertEqual(payload["surface_id"], .string(surfaceID.value.uuidString))
            XCTAssertFalse(try XCTUnwrap(payload["session_id"]?.stringValue).isEmpty)
        }
        let conflict = try XCTUnwrap(events.first { $0.kind == "files.edit.conflict" })
        XCTAssertEqual(conflict.payload.objectValue?["reason"], .string("disk_changed"))
    }

    /// WHY: file-edit CAS digests must stay CryptoKit-identical after the
    /// nibble-table path; a case drift would false-positive disk_changed or
    /// accept a silent overwrite.
    func test_workspaceFileSHA256Hex_matchesCryptoKitLowercase() {
        let samples: [Data] = [
            Data(),
            Data("hello".utf8),
            Data((0..<8_192).map { UInt8($0 & 0xff) }),
        ]
        for sample in samples {
            let expected = SHA256.hash(data: sample)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(workspaceFileSHA256Hex(sample), expected)
        }
    }
}
