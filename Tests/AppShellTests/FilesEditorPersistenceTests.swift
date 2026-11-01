import XCTest
import Foundation
import CoreModel
import SocketServer
@testable import AppShell

/// Drives the shipped `FilesViewModel` against the real file-edit session store and
/// workspace file service on a temporary directory. Unlike the routing-stub suites,
/// these tests assert what actually lands on disk, so a regression that only writes
/// the local draft (or renames only the tab) fails here.
@MainActor
final class FilesEditorPersistenceTests: XCTestCase {
    private var root: URL!
    private let service = WorkspaceFileService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FileEditSessionStore.shared.resetForTests()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// `FilesViewModel.router` is weak, so the test must keep the router alive.
    private var router: DiskRouter?

    private func makeModel() -> FilesViewModel {
        let router = DiskRouter(root: root, service: service)
        self.router = router
        return FilesViewModel(
            surfaceID: SurfaceID(),
            workspaceID: WorkspaceID(),
            root: root.path,
            router: router
        )
    }

    func test_editingAndSavingWritesTheNewContentToDisk() throws {
        let file = root.appendingPathComponent("main.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let model = makeModel()
        defer { model.close() }
        model.loadDirectory("")
        let entry = try XCTUnwrap(model.entries.first { $0.relativePath == "main.swift" })
        model.select(entry)
        XCTAssertEqual(model.draftText, "let value = 1\n")

        model.editorChanged("let value = 42\n")
        XCTAssertEqual(model.draftText, "let value = 42\n", "the binding must match typed text before a caret update redraws the editor")
        XCTAssertTrue(model.isDirty, "Save must be enabled on the first keystroke")

        model.save()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 42\n",
            "Save must persist the editor draft through the real edit session, not just clear the dirty flag")
        XCTAssertFalse(model.isDirty)
    }

    func test_newFileLandsOnDiskAndOpensAnEditableTab() throws {
        let model = makeModel()
        defer { model.close() }
        model.loadDirectory("")

        model.createFile(named: "Notes.txt")

        let onDisk = root.appendingPathComponent("Notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path),
            "the explorer New File action must create the file in the workspace")
        XCTAssertEqual(model.selectedPath, "Notes.txt")
        XCTAssertEqual(model.openTabs.map(\.relativePath), ["Notes.txt"],
            "the created file must open in an editor tab")
    }

    func test_switchingFilesImmediatelyKeepsBufferedTypingInItsOwnFile() throws {
        try "first".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "second".write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let model = makeModel()
        defer { model.close() }
        model.loadDirectory("")
        let a = try XCTUnwrap(model.entries.first { $0.relativePath == "a.swift" })
        let b = try XCTUnwrap(model.entries.first { $0.relativePath == "b.swift" })
        model.select(a)
        model.editorChanged("first edited")
        model.select(b)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(model.draftText, "second", "a pending patch must never enter the next file")
        model.select(a)
        XCTAssertEqual(model.draftText, "first edited")
        model.save()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.swift"), encoding: .utf8), "first edited")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.swift"), encoding: .utf8), "second")
    }

    func test_discardAndTypingBackToOriginalCancelBufferedEdits() throws {
        try "original".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let model = makeModel()
        defer { model.close() }
        model.loadDirectory("")
        model.select(try XCTUnwrap(model.entries.first))
        model.editorChanged("discard me")
        model.discard()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(model.draftText, "original")
        XCTAssertFalse(model.isDirty)
        model.editorChanged("temporary")
        model.editorChanged("original")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(model.draftText, "original")
        XCTAssertFalse(model.isDirty)
    }

    func test_renameMovesTheFileOnDiskAndTheTabFollows() throws {
        let file = root.appendingPathComponent("old.swift")
        try "let a = 1".write(to: file, atomically: true, encoding: .utf8)
        let model = makeModel()
        defer { model.close() }
        model.loadDirectory("")
        let entry = try XCTUnwrap(model.entries.first { $0.relativePath == "old.swift" })
        model.select(entry)

        model.rename(entry, to: "new.swift")

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
            "rename must move the original file")
        let renamed = root.appendingPathComponent("new.swift")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "let a = 1",
            "rename must preserve file contents")
        XCTAssertEqual(model.openTabs.map(\.relativePath), ["new.swift"])
        XCTAssertEqual(model.selectedPath, "new.swift")
    }

    func test_deleteRemovesTheFileFromDiskAndClosesTheTab() throws {
        let file = root.appendingPathComponent("gone.swift")
        try "let gone = true".write(to: file, atomically: true, encoding: .utf8)
        let model = makeModel()
        defer { model.close() }
        model.loadDirectory("")
        let entry = try XCTUnwrap(model.entries.first { $0.relativePath == "gone.swift" })
        model.select(entry)

        model.delete([entry])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
            "Delete must remove the file from the workspace")
        XCTAssertTrue(model.openTabs.isEmpty, "the deleted file's tab must close")
        XCTAssertNil(model.selectedEntry)
    }
}

/// Router that delegates every file operation to the real stores on a temp root.
private final class DiskRouter: FilesSurfaceRouting {
    let root: URL
    let service: WorkspaceFileService
    private var state: [String: JSONValue] = ["current_directory": .string(""), "reader_mode": .string("source")]

    init(root: URL, service: WorkspaceFileService) {
        self.root = root
        self.service = service
    }

    func filesEditClose(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.close(sessionID: sessionID)
    }

    func filesStateGet(surface: SurfaceID) throws -> JSONValue { .object(state) }

    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
        for (key, value) in patch { state[key] = value }
        return .object(state)
    }

    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
        try service.list(root: root.path, path: path)
    }

    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
        try FileEditSessionStore.shared.open(surfaceID: surface, workspaceID: WorkspaceID(), root: root.path, path: path)
    }

    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
        try service.read(root: root.path, path: path, maxBytes: maxBytes)
    }

    func filesEditSave(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.save(sessionID: sessionID)
    }

    func filesEditDiscard(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.discard(sessionID: sessionID)
    }

    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        try FileEditSessionStore.shared.applyPatch(
            sessionID: sessionID,
            baseDraftRevision: baseDraftRevision,
            rangeLocation: rangeLocation,
            rangeLength: rangeLength,
            replacement: replacement,
            deviceID: deviceID
        )
    }

    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
        try service.createFile(root: root.path, path: path, content: content)
    }

    func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
        try service.createDirectory(root: root.path, path: path)
    }

    func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
        try service.moveItem(root: root.path, sourcePath: sourcePath, destinationDirectoryPath: destinationDirectoryPath)
    }

    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
        try service.rename(root: root.path, path: path, newName: newName)
    }

    func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: .files, title: path)
    }

    func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: .files, title: path)
    }
}
