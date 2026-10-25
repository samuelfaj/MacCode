import XCTest
@testable import AppShell
import CoreModel
import SocketServer

@MainActor
final class FilesViewModelRoutingTests: XCTestCase {
    private final class FakeFilesRouter: FilesSurfaceRouting {
        var state: [String: JSONValue] = [
            "current_directory": .string(""),
            "reader_mode": .string("source"),
            "dirty_paths": .array([])
        ]
        var listings: [String: [JSONValue]] = [:]
        var contents: [String: String] = [:]
        var readIdentities: [String: [String: JSONValue]] = [:]
        var operations: [String] = []
        var sessionPathByID: [String: String] = [:]
        var onApplyPatch: ((String) -> Void)?

        func filesEditClose(sessionID: String) throws -> JSONValue {
            operations.append("close:\(sessionID)")
            return .object(["ok": .bool(true)])
        }

        func filesStateGet(surface: SurfaceID) throws -> JSONValue {
            .object(state)
        }

        func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
            let relativePath = path ?? ""
            return .object([
                "relative_path": .string(relativePath),
                "entries": .array(listings[relativePath] ?? [])
            ])
        }

        func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
            operations.append("state:\(patch.keys.sorted().joined(separator: ","))")
            for (key, value) in patch { state[key] = value }
            state["surface_id"] = .string(surface.value.uuidString)
            state["revision"] = .number(Double((state["revision"]?.intValue ?? 0) + 1))
            return .object(state)
        }

        func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
            operations.append("open:\(path)")
            sessionPathByID["session-\(path)"] = path
            return .object([
                "surface_id": .string(surface.value.uuidString),
                "path": .string(path),
                "session_id": .string("session-\(path)"),
                "draft_revision": .number(1),
                "dirty": .bool(false),
                "content": .string(contents[path] ?? "")
            ])
        }

        func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
            operations.append("read:\(path)")
            var payload: [String: JSONValue] = ["content": .string(contents[path] ?? "")]
            if let identity = readIdentities[path] {
                payload["identity"] = .object(identity)
            }
            return .object(payload)
        }

        func filesEditSave(sessionID: String) throws -> JSONValue {
            .object(["session_id": .string(sessionID), "dirty": .bool(false)])
        }

        func filesEditDiscard(sessionID: String) throws -> JSONValue {
            .object(["session_id": .string(sessionID), "dirty": .bool(false)])
        }

        func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
            operations.append("create:\(path)")
            contents[path] = content
            let parent = parentPath(for: path)
            let created = Self.fileEntry(path)
            listings[parent, default: []].append(created)
            return created
        }

        func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
            let created = Self.fileEntry(path, isDirectory: true)
            listings[parentPath(for: path), default: []].append(created)
            listings[path] = []
            return created
        }

        func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
            operations.append("move:\(sourcePath)->\(destinationDirectoryPath)")
            return .object(["ok": .bool(true)])
        }

        func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
            let parent = parentPath(for: path)
            let renamedPath = parent.isEmpty ? newName : "\(parent)/\(newName)"
            operations.append("rename:\(path)->\(renamedPath)")
            listings[parent] = (listings[parent] ?? []).filter { value in
                value.objectValue?["relative_path"]?.stringValue != path
            }
            let renamed = Self.fileEntry(renamedPath)
            listings[parent, default: []].append(renamed)
            contents[renamedPath] = contents.removeValue(forKey: path) ?? ""
            return renamed
        }

        func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
            SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
        }

        func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
            SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
        }

        func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
            let path = sessionPathByID[sessionID] ?? ""
            operations.append("patch:\(path):\(replacement)")
            onApplyPatch?(path)
            let current = contents[path] ?? ""
            let ns = current as NSString
            contents[path] = ns.replacingCharacters(in: NSRange(location: rangeLocation, length: rangeLength), with: replacement)
            return .object([
                "session_id": .string(sessionID),
                "path": .string(path),
                "draft_revision": .number(Double(baseDraftRevision + 1)),
                "dirty": .bool(true),
                "content": .string(contents[path] ?? "")
            ])
        }

        private func parentPath(for path: String) -> String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }

        static func fileEntry(_ relativePath: String, isDirectory: Bool = false) -> JSONValue {
            let name = (relativePath as NSString).lastPathComponent
            return .object([
                "name": .string(name),
                "path": .string("/workspace/\(relativePath)"),
                "relative_path": .string(relativePath),
                "type": .string(isDirectory ? "directory" : "file"),
                "size": .number(0),
                "is_hidden": .bool(name.hasPrefix(".")),
                "identity": .object([
                    "kind": .string(isDirectory ? "directory" : "text"),
                    "mime": .string(isDirectory ? "inode/directory" : "text/plain"),
                    "is_editable": .bool(!isDirectory),
                    "editability_reason": .string(isDirectory ? "directory" : "editable"),
                    "language": .string("text")
                ])
            ])
        }
    }

    private func makeModel(router: FakeFilesRouter) -> FilesViewModel {
        FilesViewModel(surfaceID: SurfaceID(), workspaceID: WorkspaceID(), root: "/workspace", router: router)
    }

    func test_loadDirectoryRendersEntriesAndPersistsCurrentDirectory() {
        let router = FakeFilesRouter()
        router.listings["src"] = [FakeFilesRouter.fileEntry("src/App.swift")]
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("src")

        XCTAssertEqual(model.currentDirectory, "src",
            "directory load must update the visible Files sidebar directory")
        XCTAssertEqual(model.entries.map(\.relativePath), ["src/App.swift"],
            "directory load must render entries returned by the router")
        XCTAssertEqual(router.state["current_directory"]?.stringValue, "src",
            "directory load must persist current_directory for restore/mirror clients")
    }

    func test_loadInitialStateKeepsWorkspaceRootAndExpandsToSelectedFile() {
        let router = FakeFilesRouter()
        router.state["selected_path"] = .string("a/b/c.txt")
        router.listings[""] = [FakeFilesRouter.fileEntry("a", isDirectory: true)]
        router.listings["a"] = [FakeFilesRouter.fileEntry("a/b", isDirectory: true)]
        router.listings["a/b"] = [FakeFilesRouter.fileEntry("a/b/c.txt")]
        router.contents["a/b/c.txt"] = "selected"
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadInitialState()

        XCTAssertEqual(model.currentDirectory, "",
            "the explorer stays rooted at the workspace like VS Code")
        XCTAssertEqual(model.expandedPaths, ["a", "a/b"],
            "restoring a selected file expands its ancestor folders instead of navigating into them")
        XCTAssertEqual(model.selectedPath, "a/b/c.txt",
            "initial state must select the restored file entry")
        XCTAssertEqual(model.draftText, "selected",
            "initial state must open the selected editable file session")
    }

    func test_entryForSelectionIDFindsExpandedNestedFile() {
        let router = FakeFilesRouter()
        router.listings[""] = [FakeFilesRouter.fileEntry("src", isDirectory: true)]
        router.listings["src"] = [FakeFilesRouter.fileEntry("src/App.swift")]
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        model.toggleExpand(model.entries[0])

        let selected = model.entryForSelectionID("/workspace/src/App.swift")

        XCTAssertEqual(selected?.relativePath, "src/App.swift",
            "clicking a file inside an expanded folder must resolve the cached row by List selection id so the file opens")
        guard let selected else {
            return XCTFail("expanded nested file selection must resolve before opening")
        }
        model.select(selected)
        XCTAssertEqual(model.selectedPath, "src/App.swift",
            "clicking a cached nested file row must open the selected file, not leave the reader empty")
        XCTAssertTrue(router.operations.contains("open:src/App.swift"),
            "clicking a cached nested file row must call filesEditOpen for the target path")
    }

    func test_selectIfNeededDoesNotReopenAlreadySelectedFile() {
        let router = FakeFilesRouter()
        router.listings[""] = [FakeFilesRouter.fileEntry("README.md")]
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let entry = model.entries[0]
        model.select(entry)
        let openCount = router.operations.filter { $0 == "open:README.md" }.count

        model.selectIfNeeded(entry)

        XCTAssertEqual(openCount, 1,
            "the first click should open the file exactly once")
        XCTAssertEqual(router.operations.filter { $0 == "open:README.md" }.count, 1,
            "tap handling and List selection changes can both fire, but the same selected file must not reopen a second edit session")
    }

    func test_selectUnknownTextUsesContentIdentityAndOpensEditor() throws {
        // WHY: extensionless text such as Dockerfile is intentionally cheap-classified as
        // unknown in directory listings, but selecting it must promote the content-based
        // identity and open the source editor without treating arbitrary binaries as text.
        let router = FakeFilesRouter()
        router.listings[""] = [.object([
            "name": .string("Dockerfile"),
            "path": .string("/workspace/Dockerfile"),
            "relative_path": .string("Dockerfile"),
            "type": .string("file"),
            "size": .number(12),
            "is_hidden": .bool(false),
            "identity": .object([
                "kind": .string("unknown"),
                "mime": .string("application/octet-stream"),
                "is_editable": .bool(false),
                "editability_reason": .string("binary or unknown file")
            ])
        ])]
        router.contents["Dockerfile"] = "FROM debian\n"
        router.readIdentities["Dockerfile"] = [
            "kind": .string("text"),
            "mime": .string("text/plain"),
            "is_editable": .bool(true),
            "editability_reason": .string("editable text")
        ]
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let listed = try XCTUnwrap(model.entries.first)
        XCTAssertFalse(listed.isEditable, "the listing must stay byte-free and conservative")
        model.select(listed)

        XCTAssertEqual(model.selectedEntry?.kind, "text")
        XCTAssertTrue(model.selectedEntry?.isEditable == true)
        XCTAssertEqual(model.draftText, "FROM debian\n")
        XCTAssertEqual(
            router.operations.filter { $0 == "open:Dockerfile" }.count,
            1,
            "content-confirmed text must receive a real edit session"
        )
    }

    func test_reselectUnknownTextRestoresDirtyDraftWithoutReopening() throws {
        // WHY: content-based promotion happens after selection. Returning to an
        // extensionless file must still honor the same dirty-session cache as files
        // whose editable identity was already known from the directory listing.
        let router = FakeFilesRouter()
        let unknown: JSONValue = .object([
            "name": .string("Dockerfile"),
            "path": .string("/workspace/Dockerfile"),
            "relative_path": .string("Dockerfile"),
            "type": .string("file"),
            "size": .number(12),
            "is_hidden": .bool(false),
            "identity": .object([
                "kind": .string("unknown"),
                "mime": .string("application/octet-stream"),
                "is_editable": .bool(false),
                "editability_reason": .string("binary or unknown file")
            ])
        ])
        router.listings[""] = [unknown, FakeFilesRouter.fileEntry("notes.txt")]
        router.contents["Dockerfile"] = "FROM debian\n"
        router.contents["notes.txt"] = "notes"
        router.readIdentities["Dockerfile"] = [
            "kind": .string("text"),
            "mime": .string("text/plain"),
            "is_editable": .bool(true),
            "editability_reason": .string("editable text")
        ]
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let dockerfile = try XCTUnwrap(model.entries.first { $0.name == "Dockerfile" })
        let notes = try XCTUnwrap(model.entries.first { $0.name == "notes.txt" })
        model.loadFile(dockerfile)
        model.draftText = "FROM debian\nRUN echo local\n"
        model.editorChanged(model.draftText)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.loadFile(notes)
        router.operations.removeAll()

        model.loadFile(dockerfile)

        XCTAssertEqual(model.draftText, "FROM debian\nRUN echo local\n")
        XCTAssertFalse(
            router.operations.contains("open:Dockerfile"),
            "reselection must restore the dirty session instead of replacing it"
        )
    }

    func test_createFileTrimsNameCreatesUnderCurrentDirectoryAndOpensIt() {
        let router = FakeFilesRouter()
        router.listings["docs"] = []
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("docs")
        model.createFile(named: " notes.md ")

        XCTAssertTrue(router.operations.contains("create:docs/notes.md"),
            "createFile must trim dialog input and call create under currentDirectory")
        XCTAssertEqual(model.selectedPath, "docs/notes.md",
            "created files should become selected and opened")
        XCTAssertTrue(model.entries.contains { $0.relativePath == "docs/notes.md" },
            "directory entries should refresh after createFile")
    }

    func test_renameOpenFileClosesSessionBeforeRenameAndReopensRenamedEntry() {
        let router = FakeFilesRouter()
        router.listings[""] = [FakeFilesRouter.fileEntry("old.txt")]
        router.contents["old.txt"] = "old"
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let entry = model.entries[0]
        model.selectedEntry = entry
        model.loadFile(entry)
        router.operations.removeAll()
        model.rename(entry, to: "new.txt")

        XCTAssertEqual(Array(router.operations.prefix(2)), ["close:session-old.txt", "rename:old.txt->new.txt"],
            "renaming the open file must close its edit session before filesystem rename")
        XCTAssertEqual(model.selectedPath, "new.txt",
            "renamed open file should be reselected")
        XCTAssertTrue(router.operations.contains("open:new.txt"),
            "renamed open file should open a fresh edit session")
    }

    func test_dirtySessionCacheRestoresDraftWithoutReopeningHostSession() {
        let router = FakeFilesRouter()
        router.listings[""] = [
            FakeFilesRouter.fileEntry("a.txt"),
            FakeFilesRouter.fileEntry("b.txt")
        ]
        router.contents["a.txt"] = "clean a"
        router.contents["b.txt"] = "clean b"
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let a = model.entries[0]
        let b = model.entries[1]
        model.loadFile(a)
        model.draftText = "dirty a"
        model.editorChanged("dirty a")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.loadFile(b)
        router.operations.removeAll()
        model.loadFile(a)

        XCTAssertEqual(model.draftText, "dirty a",
            "reselecting a dirty file must restore the cached local draft")
        XCTAssertFalse(router.operations.contains("open:a.txt"),
            "dirty cached sessions must not reopen from host and lose local draft state")
    }

    func test_reentrantEditorChangeDuringPatchCoalescesToSecondPatch() {
        let router = FakeFilesRouter()
        router.listings[""] = [FakeFilesRouter.fileEntry("a.txt")]
        router.contents["a.txt"] = ""
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.loadFile(model.entries[0])

        var didReenter = false
        router.onApplyPatch = { [weak model] path in
            guard path == "a.txt", !didReenter else { return }
            didReenter = true
            model?.draftText = "ab"
            model?.editorChanged("ab")
        }

        model.draftText = "a"
        model.editorChanged("a")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertEqual(router.operations.filter { $0.hasPrefix("patch:a.txt") }.count, 2,
            "typing again during an in-flight patch must be coalesced into exactly one follow-up patch")
        XCTAssertEqual(model.draftText, "ab",
            "the final draft should include the reentrant edit")
        XCTAssertEqual(router.contents["a.txt"], "ab",
            "the host content should receive the follow-up patch after the first patch finishes")
    }

    func test_filesSurfaceFilter_dropsStreamKindsAndKeepsEditKinds() {
        // WHY: each open Files tab used to hop every EventBus event (incl.
        // ~30 Hz agent.item.delta) to main, then drop it in receive(). The
        // admission filter must keep edit/state and reject the stream firehose.
        let filter = EventStreamFilter.filesSurface
        func event(_ kind: String) -> EventBus.Event {
            EventBus.Event(seq: 1, kind: kind, payload: .null, ts: 0)
        }

        XCTAssertTrue(filter.allows(event("files.state.updated")))
        XCTAssertTrue(filter.allows(event("files.edit.opened")))
        XCTAssertTrue(filter.allows(event("files.edit.patch_applied")))
        XCTAssertTrue(filter.allows(event("files.edit.saved")))
        XCTAssertTrue(filter.allows(event("files.edit.discarded")))
        XCTAssertTrue(filter.allows(event("files.edit.conflict")))
        XCTAssertTrue(filter.allows(event("files.edit.closed")))
        XCTAssertFalse(filter.allows(event("agent.item.delta")),
            "token-rate deltas must not admit a Files tab handler")
        XCTAssertFalse(filter.allows(event("agent.item.progress")))
        XCTAssertFalse(filter.allows(event("surface.output")))
        XCTAssertFalse(filter.allows(event("workspace.selected")))
    }

    func test_streamEventsDoNotHopFilesSurfaceToMain() {
        // WHY: proof that the subscribe filter actually gates receive(), not
        // just the pure admission table. Three stream publishes + one files
        // state event must increment the receive counter once.
        let router = FakeFilesRouter()
        let model = makeModel(router: router)
        defer { model.close() }

        EventBus.shared.publish(kind: .agentItemDelta, payload: .object([
            "item_id": .string("i1"),
            "body_append": .string("x")
        ]))
        EventBus.shared.publish(kind: .agentItemProgress, payload: .object([
            "item_id": .string("i1"),
            "progress": .number(0.5)
        ]))
        EventBus.shared.publish(kind: .surfaceOutput, payload: .object([
            "surface_id": .string("term")
        ]))
        drainMainQueue()
        XCTAssertEqual(model.eventReceiveCountForTests, 0,
            "stream kinds must be dropped on the EventBus delivery thread")

        EventBus.shared.publish(kind: .filesStateUpdated, payload: .object([
            "surface_id": .string(model.surfaceID.value.uuidString),
            "state": .object([
                "current_directory": .string("src"),
                "reader_mode": .string("source")
            ])
        ]))
        drainMainQueue()
        XCTAssertEqual(model.eventReceiveCountForTests, 1,
            "files.state.updated must still reach receive so dirty/dir state stays live")
        XCTAssertEqual(model.currentDirectory, "src",
            "admitted files.state.updated must still apply")
    }

    private func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
