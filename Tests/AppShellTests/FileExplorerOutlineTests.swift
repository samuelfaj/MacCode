import XCTest
import AppKit
import Foundation
import CoreModel
import SocketServer
@testable import AppShell

/// Drives the shipped NSOutlineView explorer and its model against a real temp workspace.
@MainActor
final class FileExplorerOutlineTests: XCTestCase {
    private var root: URL!
    private let service = WorkspaceFileService()
    private var router: ExplorerDiskRouter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-explorer-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src/lib/stores"), withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("src/lib/stores/theme.js"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("src/app.css"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        router = ExplorerDiskRouter(root: root, service: service)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> FilesViewModel {
        FilesViewModel(surfaceID: SurfaceID(), workspaceID: WorkspaceID(), root: root.path, router: router)
    }

    /// Hosts the real representable's NSOutlineView in a window so AppKit drives the data source.
    private func host(_ model: FilesViewModel) -> (NSWindow, NSOutlineView) {
        let view = FileExplorerOutline(model: model, showHidden: false, onNewFile: { _ in }, onNewFolder: { _ in }, onRequestDelete: { _ in })
        let hosting = NSHostingView(rootView: view.frame(width: 300, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        pump()
        let outline = try! XCTUnwrap(Self.find(NSOutlineView.self, in: hosting))
        return (window, outline)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func rowNames(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? ExplorerNode)?.entry.name }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.1)
        }
        return condition()
    }

    func test_outlineIsNativeAndListsLazily() {
        let model = makeModel()
        defer { model.close() }
        model.loadInitialState()
        let (window, outline) = host(model)
        defer { window.close() }

        XCTAssertTrue(outline is ExplorerOutlineView, "explorer must be the AppKit outline, not a SwiftUI List")
        XCTAssertEqual(outline.rowHeight, ExplorerStyle.rowHeight)
        XCTAssertEqual(rowNames(outline).sorted(), ["package.json", "src"],
            "collapsed folders must not list their children")

        let src = outline.item(atRow: rowNames(outline).firstIndex(of: "src")!)
        outline.expandItem(src)
        pump()
        XCTAssertEqual(Set(rowNames(outline)), ["src", "lib", "app.css", "package.json"],
            "expanding a folder lists its children from disk")
        XCTAssertTrue(model.expandedPaths.contains("src"), "AppKit expansion must flow into the model")
    }

    func test_createInNestedFolderRenameAndMoveHitDiskAndKeepExpansion() throws {
        let model = makeModel()
        defer { model.close() }
        model.loadInitialState()
        model.expandedPaths = ["src", "src/lib"]
        let (window, outline) = host(model)
        defer { window.close() }

        let lib = try XCTUnwrap(model.childEntries(for: try XCTUnwrap(model.entries.first { $0.name == "src" })).first { $0.name == "lib" })
        model.createFile(named: "new.js", in: model.explorerTargetDirectory(for: lib))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("src/lib/new.js").path))
        pump()
        XCTAssertTrue(rowNames(outline).contains("new.js"), "new file must appear without collapsing the tree")
        XCTAssertEqual(model.expandedPaths, ["src", "src/lib"])

        let created = try XCTUnwrap(model.allKnownEntry(relativePath: "src/lib/new.js"))
        model.rename(created, to: "renamed.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("src/lib/renamed.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("src/lib/new.js").path))

        let renamed = try XCTUnwrap(model.allKnownEntry(relativePath: "src/lib/renamed.js"))
        model.moveEntry(renamed, intoDirWithPath: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.js").path))
        pump()
        XCTAssertTrue(rowNames(outline).contains("renamed.js"))
        XCTAssertTrue(model.expandedPaths.contains("src/lib"), "mutations must not reset expansion")
    }

    func test_expansionPersistsAndRestoresInANewModel() {
        let first = makeModel()
        first.loadInitialState()
        first.expandedPaths = ["src", "src/lib", "gone"]
        first.close()
        XCTAssertEqual(router.state["expanded_dirs"], .array([.string("gone"), .string("src"), .string("src/lib")]),
            "expanded folders must be written to surface state")

        let second = makeModel()
        defer { second.close() }
        second.loadInitialState()
        XCTAssertEqual(second.expandedPaths, ["src", "src/lib"],
            "restore must re-expand folders that still exist and drop missing ones")
    }

    func test_watcherShowsExternallyCreatedFile() throws {
        let model = makeModel()
        defer { model.close() }
        model.loadInitialState()
        let (window, outline) = host(model)
        defer { window.close() }
        try "x".write(to: root.appendingPathComponent("external.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { self.rowNames(outline).contains("external.txt") },
            "FSEvents must refresh the tree when a file appears on disk")
    }

    func test_gitPorcelainParserMarksFilesAndAncestors() throws {
        let git = { (args: [String]) throws in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", self.root.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["-c", "user.email=a@b", "-c", "user.name=t", "commit", "-qm", "init"])
        try "changed".write(to: root.appendingPathComponent("src/lib/stores/theme.js"), atomically: true, encoding: .utf8)
        try "new".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let statuses = try XCTUnwrap(readGitStatuses(root: root.path))
        XCTAssertEqual(statuses["src/lib/stores/theme.js"], .modified)
        XCTAssertEqual(statuses["notes.md"], .untracked)
        XCTAssertEqual(statuses["src"], .containsChanges)
        XCTAssertEqual(statuses["src/lib/stores"], .containsChanges)
        XCTAssertNil(statuses["package.json"])

        // Workspace that is a subfolder of the repo: paths are relative to it.
        let sub = try XCTUnwrap(readGitStatuses(root: root.appendingPathComponent("src").path))
        XCTAssertEqual(sub["lib/stores/theme.js"], .modified)
        XCTAssertNil(sub["notes.md"], "paths outside the workspace are dropped")
    }

    func test_parserHandlesRenameRecords() {
        let parsed = parseGitPorcelain("R  new.js\0old.js\0 M a/b.txt\0", prefix: "")
        XCTAssertEqual(parsed["new.js"], .modified)
        XCTAssertNil(parsed["old.js"])
        XCTAssertEqual(parsed["a/b.txt"], .modified)
        XCTAssertEqual(parsed["a"], .containsChanges)
    }

    func test_copyIntoFolderNeverOverwrites() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).json")
        try "dropped".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let named = root.appendingPathComponent(outside.lastPathComponent)
        try "original".write(to: named, atomically: true, encoding: .utf8)
        try copyIntoFolder([outside], folder: root)
        XCTAssertEqual(try String(contentsOf: named, encoding: .utf8), "original")
        let copy = root.appendingPathComponent(outside.deletingPathExtension().lastPathComponent + " copy.json")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "dropped")
    }
}

private final class ExplorerDiskRouter: FilesSurfaceRouting {
    let root: URL
    let service: WorkspaceFileService
    var state: [String: JSONValue] = ["current_directory": .string(""), "reader_mode": .string("source")]

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
