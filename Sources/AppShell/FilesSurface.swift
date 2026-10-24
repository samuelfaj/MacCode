import Foundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import AVKit
import CoreModel
import SocketServer
import Surfaces
import DesignSystemKit
import os

// Structured telemetry for the Files surface. Logs operation + error code + coarse size bucket
// only - never paths or file contents - so field save/conflict/decode failures are visible
// without leaking PII (QA-MAC_FILES-008).
private let filesLog = Logger(subsystem: "io.remotecode.appshell", category: "files")

private func sizeBucket(_ bytes: Int) -> String {
    switch bytes {
    case ..<0: return "unknown"
    case 0..<16_384: return "<16KB"
    case 16_384..<262_144: return "16KB-256KB"
    case 262_144..<2_097_152: return "256KB-2MB"
    case 2_097_152..<67_108_864: return "2MB-64MB"
    default: return ">64MB"
    }
}

@MainActor
final class FilesSurface: NSObject, Surface {
    private(set) var descriptor: SurfaceDescriptor
    let view: NSView
    private let model: FilesViewModel

    init(workspaceID: WorkspaceID, cwd: String, title: String = "Files", router: AppCommandRouter, initialState: String?, selectedPath: String? = nil) {
        var metadata = ["workspace": workspaceID.value.uuidString, "cwd": cwd]
        if let initialState { metadata["files_state"] = initialState }
        if let selectedPath {
            metadata["selected_path"] = selectedPath
            metadata["selected_relative_path"] = selectedPath
        }
        self.descriptor = SurfaceDescriptor(type: .files, title: title, iconName: "folder", metadata: metadata)
        self.model = FilesViewModel(
            surfaceID: descriptor.id,
            workspaceID: workspaceID,
            root: cwd,
            router: router,
            inlineCompletionProvider: DistillInlineCompletionProvider.distillCLI()
        )
        self.view = NSHostingView(rootView: FilesSurfaceRoot(model: model))
        super.init()
        DispatchQueue.main.async { [model] in model.loadInitialState() }
    }

    func focus() { view.window?.makeFirstResponder(view) }
    func unfocus() {}
    func close() { model.close() }
    func sendText(_ text: String) { model.insertText(text) }
    func readText() -> String { model.visibleText }
    func snapshot() -> [String: String] { ["selected_path": model.selectedPath ?? ""] }

    /// UX-MAC_AGENT-OPEN-SPLIT: programmatic navigation used when the Agent App
    /// reuses this panel as the right-hand split for a clicked file mention.
    func reveal(relativePath: String) { model.reveal(relativePath: relativePath) }
}

struct FileTabDragPayload {
    static let prefix = "rc-file-tab|"
    let workspaceID: String
    let sourceSurfaceID: String
    let path: String

    static func encode(workspaceID: WorkspaceID, sourceSurfaceID: SurfaceID, path: String) -> String {
        let encodedPath = Data(path.utf8).base64EncodedString()
        return "\(prefix)\(workspaceID.value.uuidString)|\(sourceSurfaceID.value.uuidString)|\(encodedPath)"
    }

    static func decode(_ value: String) -> FileTabDragPayload? {
        guard value.hasPrefix(prefix) else { return nil }
        let raw = String(value.dropFirst(prefix.count))
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let data = Data(base64Encoded: parts[2]),
              let path = String(data: data, encoding: .utf8),
              !path.isEmpty else { return nil }
        return FileTabDragPayload(workspaceID: parts[0], sourceSurfaceID: parts[1], path: path)
    }
}

/// Drag payload for sidebar move-to-folder. Encodes workspace + relative source path so the
/// drop target (a directory row) knows which item to move and into which workspace.
private struct SidebarMoveDragPayload {
    static let prefix = "rc-sidebar-move|"
    let workspaceID: String
    let relativePath: String

    static func encode(workspaceID: WorkspaceID, relativePath: String) -> String {
        let encoded = Data(relativePath.utf8).base64EncodedString()
        return "\(prefix)\(workspaceID.value.uuidString)|\(encoded)"
    }

    static func decode(_ value: String) -> SidebarMoveDragPayload? {
        guard value.hasPrefix(prefix) else { return nil }
        let raw = String(value.dropFirst(prefix.count))
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let data = Data(base64Encoded: parts[1]),
              let path = String(data: data, encoding: .utf8) else { return nil }
        return SidebarMoveDragPayload(workspaceID: parts[0], relativePath: path)
    }
}

struct FileEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let relativePath: String
    let isDirectory: Bool
    let kind: String
    let mime: String
    let size: Int
    let modifiedAt: Double?
    let isHidden: Bool
    let isEditable: Bool
    let editabilityReason: String
    let language: String?
    // Precomputed once per entry so List rows don't recompute the icon or re-encode the base64
    // drag payload on every redraw (PERF-MAC_FILES-010). `dragPayload` is filled in by the VM,
    // which holds the workspace/surface IDs the payload needs.
    let icon: String
    var dragPayload: String?
    // Sidebar move drag payload (both files and directories can be dragged into a folder).
    var moveDragPayload: String?

    init?(value: JSONValue) {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              let path = object["path"]?.stringValue,
              let relative = object["relative_path"]?.stringValue,
              let identity = object["identity"]?.objectValue else { return nil }
        self.name = name
        self.path = path
        self.relativePath = relative
        self.id = path
        let isDirectory = object["type"]?.stringValue == "directory"
        self.isDirectory = isDirectory
        let kind = identity["kind"]?.stringValue ?? (isDirectory ? "directory" : "unknown")
        self.kind = kind
        self.mime = identity["mime"]?.stringValue ?? "application/octet-stream"
        self.size = object["size"]?.intValue ?? 0
        self.modifiedAt = object["modified_at"]?.doubleValue
        self.isHidden = object["is_hidden"]?.boolValue == true
        self.isEditable = identity["is_editable"]?.boolValue == true
        self.editabilityReason = identity["editability_reason"]?.stringValue ?? "not editable"
        self.language = identity["language"]?.stringValue
        // Use per-extension icon for files when the extension is recognised; fall back to the
        // coarser kind-based icon so MIME-detected files (e.g. a detected image with no
        // recognisable extension) still get the right icon.
        if isDirectory {
            self.icon = "folder"
        } else {
            let extIcon = fileIcon(for: name)
            self.icon = extIcon != "doc" ? extIcon : Self.icon(isDirectory: false, kind: kind)
        }
    }

    func replacingIdentity(_ identity: [String: JSONValue]) -> FileEntry? {
        var resolved = FileEntry(value: .object([
            "name": .string(name),
            "path": .string(path),
            "relative_path": .string(relativePath),
            "type": .string(isDirectory ? "directory" : "file"),
            "size": .number(Double(size)),
            "modified_at": modifiedAt.map(JSONValue.number) ?? .null,
            "is_hidden": .bool(isHidden),
            "identity": .object(identity),
        ]))
        resolved?.dragPayload = dragPayload
        resolved?.moveDragPayload = moveDragPayload
        return resolved
    }

    /// Minimal entry for restoring a persisted open tab before its identity
    /// is refreshed by `filesEditOpen` / `fsWorkspaceRead`.
    static func placeholder(relativePath: String, root: String) -> FileEntry? {
        let name = (relativePath as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let path = (root as NSString).appendingPathComponent(relativePath)
        return FileEntry(value: .object([
            "name": .string(name),
            "path": .string(path),
            "relative_path": .string(relativePath),
            "type": .string("file"),
            "size": .number(0),
            "is_hidden": .bool(false),
            "identity": .object([
                "kind": .string("code"),
                "mime": .string("text/plain"),
                "is_editable": .bool(true),
                "editability_reason": .string("editable"),
            ]),
        ]))
    }

    static func icon(isDirectory: Bool, kind: String) -> String {
        if isDirectory { return "folder" }
        switch kind {
        case "markdown": return "doc.richtext"
        case "html": return "globe"
        case "image": return "photo"
        case "video": return "play.rectangle"
        case "pdf": return "doc.text.magnifyingglass"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

// MARK: - Lazy file tree model
//
// The sidebar renders a hierarchical tree (P1): directory rows are expandable and their children
// are fetched lazily the first time the row is expanded, instead of re-listing the whole directory
// on navigation. The nesting/lazy-fetch logic is isolated here, generic over a minimal item
// protocol and a child-lister closure, so it can be unit-tested without AppKit/WebKit or the real
// filesystem (the production lister is `router.fsWorkspaceList`; tests inject a stub).

/// Minimal shape a row needs to participate in the lazy tree. `FileEntry` conforms in production;
/// tests supply a lightweight stub so the nesting/lazy-fetch logic can be exercised in isolation.
protocol FileTreeItem: Identifiable, Equatable where ID == String {
    var name: String { get }
    var relativePath: String { get }
    var isDirectory: Bool { get }
}

/// A node in the lazy tree. `children == nil` means "directory not expanded yet / children not
/// fetched"; an empty array means "expanded and confirmed empty". Leaves keep `children == nil`
/// permanently since they are never expanded.
final class FileTreeNode<Item: FileTreeItem>: Identifiable {
    let item: Item
    var children: [FileTreeNode<Item>]?
    var isExpanded: Bool

    var id: String { item.id }

    init(item: Item, children: [FileTreeNode<Item>]? = nil, isExpanded: Bool = false) {
        self.item = item
        self.children = children
        self.isExpanded = isExpanded
    }
}

/// Builds a node tree from flat per-directory listings and fetches each directory's children lazily
/// on first expand. Owns no IO itself: the `lister` closure (path -> entries) is injected, so the
/// real fetch path (security-scoped `fsWorkspaceList`) is unchanged and the logic stays testable.
final class FileTreeStore<Item: FileTreeItem> {
    /// Peak distinct directory paths retained in the lazy child listing cache.
    /// Deep monorepo expand storms otherwise pin unbounded path→entries maps
    /// until `setRoots` (cwd change). 256 matches discovery/probe cache order
    /// of magnitude for long-lived path-keyed maps.
    static var childCacheCountLimit: Int { 256 }

    /// path (relative; "" = directory whose children these are) -> entries directly under it.
    private let lister: (String) throws -> [Item]
    private(set) var roots: [FileTreeNode<Item>] = []
    /// Path-keyed cache of fetched children, shared with the node API so the SwiftUI tree (which
    /// renders by path) and the node-based contract both consult one fetch + one cache.
    private var childCache: [String: [Item]] = [:]
    private let cacheCountLimit: Int

    init(
        lister: @escaping (String) throws -> [Item],
        childCacheCountLimit: Int = FileTreeStore.childCacheCountLimit
    ) {
        self.lister = lister
        self.cacheCountLimit = max(1, childCacheCountLimit)
    }

    /// Seed the top level from an already-fetched flat listing (the directory currently shown),
    /// so the first paint costs nothing extra over the old flat list. Clears any cached subtree
    /// since a new top level invalidates the previous tree.
    func setRoots(_ items: [Item]) {
        roots = items.map { FileTreeNode(item: $0) }
        childCache = [:]
    }

    /// Test seam: number of path keys currently held in the child listing cache.
    var childCacheCountForTesting: Int { childCache.count }

    /// Expand a directory node, fetching its children the first time only. A node already carrying
    /// `children` is not re-fetched (`force` re-lists, e.g. after a mutation in that directory).
    /// Returns false and stays collapsed if the lazy fetch throws, so a failed listing doesn't
    /// leave the row in a lying "expanded but empty" state.
    @discardableResult
    func expand(_ node: FileTreeNode<Item>, force: Bool = false) -> Bool {
        guard node.item.isDirectory else { return false }
        if node.children == nil || force {
            do {
                let fetched = try fetch(node.item.relativePath, force: force)
                node.children = fetched.map { FileTreeNode(item: $0) }
            } catch {
                node.children = nil
                node.isExpanded = false
                return false
            }
        }
        node.isExpanded = true
        return true
    }

    func collapse(_ node: FileTreeNode<Item>) {
        node.isExpanded = false
    }

    /// Children directly under `path`, fetched lazily on first request and cached. Used by the
    /// path-addressed SwiftUI tree; shares the cache and lister with the node API. A failed fetch
    /// yields `[]` without caching, so the row can retry instead of sticking as empty.
    func children(at path: String) -> [Item] {
        (try? fetch(path, force: false)) ?? []
    }

    func cachedItem(relativePath: String) -> Item? {
        if let root = roots.first(where: { $0.item.relativePath == relativePath }) {
            return root.item
        }
        return childCache.values.lazy
            .flatMap { $0 }
            .first(where: { $0.relativePath == relativePath })
    }

    func cachedItem(id: String) -> Item? {
        if let root = roots.first(where: { $0.item.id == id }) {
            return root.item
        }
        return childCache.values.lazy
            .flatMap { $0 }
            .first(where: { $0.id == id })
    }

    private func fetch(_ path: String, force: Bool) throws -> [Item] {
        if !force, let cached = childCache[path] { return cached }
        let fetched = try lister(path)
        Self.noteChildCacheEntry(
            &childCache,
            path: path,
            items: fetched,
            countLimit: cacheCountLimit
        )
        return fetched
    }

    /// Pure insert/evict for the path→children listing cache. Keeps `path`;
    /// drops arbitrary other directory keys when over `countLimit`. Evicted
    /// paths re-list on next expand (cold-start / force parity).
    static func noteChildCacheEntry(
        _ cache: inout [String: [Item]],
        path: String,
        items: [Item],
        countLimit: Int = FileTreeStore.childCacheCountLimit
    ) {
        cache[path] = items
        let cap = max(1, countLimit)
        while cache.count > cap {
            if let victim = cache.keys.first(where: { $0 != path }) ?? cache.keys.first {
                cache.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }
}

extension FileEntry: FileTreeItem {}
extension FileEntry: FileNameFilterable {}

@MainActor
protocol FilesSurfaceRouting: AnyObject {
    func filesEditClose(sessionID: String) throws -> JSONValue
    func filesStateGet(surface: SurfaceID) throws -> JSONValue
    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue
    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue
    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue
    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue
    func filesEditSave(sessionID: String) throws -> JSONValue
    func filesEditDiscard(sessionID: String) throws -> JSONValue
    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue
    func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue
    func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue
    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue
    func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor
    func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor
    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue
}

extension AppCommandRouter: FilesSurfaceRouting {}

// MARK: - Pure per-extension icon helper (no AppKit, no MainActor; tested in FileExtensionIconTests)

/// Map a filename (or bare extension) to a distinct SF Symbol name based on its extension.
/// Extension matching is case-insensitive. Returns "doc" for unrecognised extensions.
/// This is a pure free function - no MainActor, no AppKit - so it can be unit-tested directly.
func fileIcon(for filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":                   return "swift"
    case "js", "jsx":               return "curlybraces"
    case "ts", "tsx":               return "curlybraces.square"
    case "json":                    return "ellipsis.curlybraces"
    case "yml", "yaml":             return "gearshape"
    case "md", "markdown":          return "doc.richtext"
    case "png", "jpg", "jpeg",
         "gif", "webp", "bmp",
         "tiff", "tif", "heic":     return "photo"
    case "svg":                     return "paintpalette"
    case "html", "htm":             return "globe"
    case "css", "scss", "less":     return "paintbrush"
    case "sh", "bash", "zsh",
         "fish", "command":         return "terminal"
    case "py":                      return "chevron.left.forwardslash.chevron.right"
    case "rb":                      return "diamond"
    case "go":                      return "hare"
    case "rs":                      return "gearshape.2"
    case "pdf":                     return "doc.text.magnifyingglass"
    case "mp4", "mov", "avi",
         "mkv", "webm":             return "play.rectangle"
    case "mp3", "wav", "aiff",
         "flac", "m4a":             return "music.note"
    case "zip", "tar", "gz",
         "bz2", "xz", "7z",
         "rar":                     return "archivebox"
    case "txt":                     return "doc.text"
    case "xml", "plist":            return "chevron.left.forwardslash.chevron.right"
    default:                        return "doc"
    }
}

// MARK: - Pure path helpers (no AppKit, no MainActor; tested in FilesNewFolderMoveTests)

/// Build the relative path for a new folder inside `parent`, uniquifying the name when a sibling
/// with the same name already exists. `existingNames` is the set of names already present directly
/// under `parent`; the helper appends " 2", " 3", ... until it finds an unused slot.
/// Both `parent` and the returned path use forward-slash separators and no leading slash.
func newFolderTargetPath(parent: String, name: String, existingNames: Set<String>) -> String {
    var candidate = name
    var counter = 2
    while existingNames.contains(candidate) {
        candidate = "\(name) \(counter)"
        counter += 1
    }
    return parent.isEmpty ? candidate : "\(parent)/\(candidate)"
}

func initialFilesDirectory(stateDirectory: String, selectedPath: String?) -> String {
    guard stateDirectory.isEmpty, let selectedPath else { return stateDirectory }
    let parent = (selectedPath as NSString).deletingLastPathComponent
    return parent == "." ? "" : parent
}

func newFileTargetPath(parent: String, rawName: String) -> String? {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    return parent.isEmpty ? name : "\(parent)/\(name)"
}

/// Validate whether moving `src` into the directory `dstDir` is safe within `workspaceRoot`.
/// Returns `false` (reject) when:
///  - `src` or `dstDir` escapes `workspaceRoot`
///  - `dstDir` is the same as `src` (move-into-self)
///  - `dstDir` is a descendant of `src` (would create a cycle)
/// All paths should be absolute (starting with "/").
func validateMove(src: String, dstDir: String, workspaceRoot: String) -> Bool {
    let root = workspaceRoot.hasSuffix("/") ? workspaceRoot : workspaceRoot + "/"
    let srcN = src.hasSuffix("/") ? src : src + "/"
    let dstN = dstDir.hasSuffix("/") ? dstDir : dstDir + "/"
    // Both must be inside the workspace.
    guard srcN.hasPrefix(root) || src == workspaceRoot else { return false }
    guard dstN.hasPrefix(root) || dstDir == workspaceRoot else { return false }
    // dstDir must not be src itself.
    guard dstDir != src else { return false }
    // dstDir must not be a descendant of src.
    guard !dstN.hasPrefix(srcN) else { return false }
    return true
}

// MARK: - Pure edit-session close-on-switch helper (no AppKit, no MainActor; tested in FilesEditSessionCloseTests)

/// Decide whether the previous edit session should be closed when switching to a different file.
///
/// Returns `true` (close the prior session) when ALL of:
///  - `prevPath` is non-nil (there was a prior file open)
///  - `prevPath != newPath` (user switched to a different file)
///  - `prevIsDirty == false` (clean sessions have no unsaved work; close them to bound host-side
///    session count. Dirty sessions are kept open so the snapshotted sessionID remains valid for
///    a future restore, preserving unsaved edits across file switches.)
///
/// This is the sole decision point for the session-close-on-switch policy so it can be
/// exercised without constructing FilesViewModel or touching AppKit.
nonisolated func shouldClosePriorEditSession(prevPath: String?, prevIsDirty: Bool, newPath: String) -> Bool {
    guard let prevPath, prevPath != newPath else { return false }
    return !prevIsDirty
}

// MARK: - Pure recycle-URL helper (no AppKit, no MainActor; tested in FilesRecycleTests)

/// Build the URL array for NSWorkspace.recycle from absolute file-system paths.
/// Pure function: no AppKit dependency, no MainActor - accepts the absolute `path` values
/// stored on each FileEntry, so the delete-to-Trash path is testable without constructing
/// the full FileEntry or touching AppKit.
func recycleURLs(forAbsolutePaths paths: [String]) -> [URL] {
    paths.map { URL(fileURLWithPath: $0) }
}

// MARK: - Pure drag-out helper (no AppKit, no MainActor; tested in FilesDragOutTests)

/// Result of resolving a file-row drag that leaves the sidebar toward Finder or another app.
/// Both fields are computed from the absolute `path` stored on `FileEntry`; no AppKit is needed.
struct FileOutDragInfo: Equatable {
    /// File URL passed to NSFilePromiseProvider / NSPasteboard so the drop target (Finder,
    /// another app) can locate the actual file on disk.
    let absoluteURL: URL
    /// Suggested filename the receiving app shows when the promise is fulfilled.
    /// Equals `URL(fileURLWithPath: absolutePath).lastPathComponent`, which is the `name`
    /// field on `FileEntry` (guaranteed non-empty by the server API).
    let promiseFilename: String
    let typeIdentifier: String
}

/// Compute the drag-out info for a single sidebar row. Pure: no AppKit, no MainActor.
/// `absolutePath` is `FileEntry.path` (always an absolute filesystem path).
/// Works identically for files and directories; directories can also be dragged to Finder.
func fileOutDragInfo(absolutePath: String) -> FileOutDragInfo {
    let url = URL(fileURLWithPath: absolutePath)
    let type = UTType(filenameExtension: url.pathExtension) ?? .item
    return FileOutDragInfo(absoluteURL: url, promiseFilename: url.lastPathComponent, typeIdentifier: type.identifier)
}

func fileOutCombinedDragPayload(fileTabPayload: String?, movePayload: String?) -> String? {
    var payloads: [String] = []
    payloads.reserveCapacity(2)
    if let payload = fileTabPayload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty {
        payloads.append(payload)
    }
    if let payload = movePayload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty {
        payloads.append(payload)
    }
    return payloads.isEmpty ? nil : payloads.joined(separator: "\n")
}

private func dragPayloadCandidates(_ raw: String) -> [String] {
    raw.split(whereSeparator: \.isNewline).map(String.init)
}

func fileTabDragPayloadCandidate(in raw: String) -> String? {
    dragPayloadCandidates(raw).first { FileTabDragPayload.decode($0) != nil }
}

func sidebarMoveDragPayloadCandidate(in raw: String) -> String? {
    dragPayloadCandidates(raw).first { SidebarMoveDragPayload.decode($0) != nil }
}

func fileTabDropPath(rawPayload: String, workspaceID: WorkspaceID) -> String? {
    guard let rawPayload = fileTabDragPayloadCandidate(in: rawPayload),
          let payload = FileTabDragPayload.decode(rawPayload),
          payload.workspaceID == workspaceID.value.uuidString else { return nil }
    return payload.path
}

func fileDropSplitDirection(location: CGPoint, size: CGSize) -> SplitDirection {
    location.y >= size.height * 0.68 ? .down : .right
}

func fileOutItemProvider(info: FileOutDragInfo, textPayload: String?) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = info.promiseFilename
    if let textPayload {
        provider.registerObject(textPayload as NSString, visibility: .all)
    }
    provider.registerObject(info.absoluteURL as NSURL, visibility: .all)
    provider.registerFileRepresentation(
        forTypeIdentifier: info.typeIdentifier,
        fileOptions: [.openInPlace],
        visibility: .all
    ) { completion in
        completion(info.absoluteURL, true, nil)
        return nil
    }
    return provider
}

// MARK: - Pure name-filter helper (no AppKit, no MainActor; tested in FilesNameFilterTests)

/// Minimal protocol surface that `filterFileEntries` requires, so the helper can be tested
/// with a lightweight stub without constructing a real `FileEntry`.
protocol FileNameFilterable {
    var name: String { get }
}

/// A lightweight stub used by `FilesNameFilterTests`; production code uses `FileEntry` directly.
struct FilterableFileEntry: FileNameFilterable {
    let name: String
    let isDirectory: Bool
}

/// Filter `entries` to those whose `name` contains `query` as a case-insensitive substring or
/// subsequence. Returns the original array unchanged when `query` is empty/whitespace.
/// Preserves the original order of matching entries.
func filterFileEntries<T: FileNameFilterable>(_ entries: [T], query: String) -> [T] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return entries }
    let lower = trimmed.lowercased()
    return entries.filter { entry in
        // PERF: avoid per-entry `lowercased()` allocation on every keystroke/body eval.
        // `range(of:options:.caseInsensitive)` is allocation-free for the haystack.
        if entry.name.range(of: lower, options: .caseInsensitive) != nil { return true }
        return isSubsequenceCaseInsensitive(lower, of: entry.name)
    }
}

private func isSubsequenceCaseInsensitive(_ needle: String, of haystack: String) -> Bool {
    return CommandPaletteFilter.isSubsequenceCaseInsensitive(needle, haystack: haystack)
}

func visibleFileEntries<T: FileNameFilterable>(
    _ entries: [T],
    showHidden: Bool,
    query: String,
    isHidden: (T) -> Bool
) -> [T] {
    let base = showHidden ? entries : entries.filter { !isHidden($0) }
    return filterFileEntries(base, query: query)
}

// PERF: path-bar submit trims leading/trailing slashes on every relative
// submission; share one slash CharacterSet instead of allocating per call.
private let filesPathSlashTrimSet = CharacterSet(charactersIn: "/")

func resolveSubmittedFilesPath(raw: String, root: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed == root || trimmed == "/" { return "" }
    if trimmed.hasPrefix(root + "/") {
        return String(trimmed.dropFirst(root.count + 1))
    }
    return trimmed.trimmingCharacters(in: filesPathSlashTrimSet)
}

func shouldGateLargeMedia(size: Int, loadAnyway: Bool, threshold: Int = LargeMediaGuardThreshold) -> Bool {
    size > threshold && !loadAnyway
}

let LargeMediaGuardThreshold = 64 * 1024 * 1024

/// Longest decoded edge for Files image preview. Matches File Preview so a
/// 12 MP screenshot does not pin 4096² RGBA (~64 MiB) in the process.
let FilesImageThumbnailMaxPixelSize = 2048

func decodeFilesImageThumbnail(url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: FilesImageThumbnailMaxPixelSize
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

struct BinaryMetadataRow: Equatable {
    let label: String
    let value: String
}

func binaryMetadataRows(relativePath: String, mime: String, size: Int) -> [BinaryMetadataRow] {
    [
        BinaryMetadataRow(label: "Path", value: relativePath),
        BinaryMetadataRow(label: "MIME", value: mime),
        BinaryMetadataRow(label: "Size", value: "\(size) bytes")
    ]
}

// MARK: - Incremental highlight range helper (no AppKit, no MainActor; tested in IncrementalHighlightRangesTests)

/// Compute the UTF-16 NSRanges (over `newText`) of lines that differ between `oldText` and
/// `newText`, so the code editor can re-highlight only the changed region instead of rebuilding
/// the entire attributed string on every remote patch (PERF-MAC_FILES-014).
///
/// Algorithm:
///  1. Split both strings into lines on "\n". NSString line enumeration is used for the final
///     range computation so offsets are UTF-16 - matching NSTextStorage expectations - and the
///     helper is safe for any Unicode content (no UTF-16 index arithmetic on grapheme clusters).
///  2. Diff line arrays from both ends (common-prefix / common-suffix trim) to find the first
///     and last changed line indices in `newText`.
///  3. Return those lines' combined UTF-16 NSRange in `newText`, or an empty array when the
///     texts are identical.
///
/// Returns at most one element (the union of all changed lines) to keep the call site simple.
/// The caller highlights every line inside that range, which is safe for multi-line tokens.
nonisolated func changedLineRanges(oldText: String, newText: String) -> [NSRange] {
    guard oldText != newText else { return [] }
    let oldLines = oldText.components(separatedBy: "\n")
    let newLines = newText.components(separatedBy: "\n")
    let oldCount = oldLines.count
    let newCount = newLines.count
    // Trim common prefix lines.
    var prefixCount = 0
    let maxPrefix = min(oldCount, newCount)
    while prefixCount < maxPrefix && oldLines[prefixCount] == newLines[prefixCount] {
        prefixCount += 1
    }
    // Trim common suffix lines (never overlap the already-trimmed prefix).
    var suffixCount = 0
    let maxSuffix = min(oldCount, newCount) - prefixCount
    while suffixCount < maxSuffix
            && oldLines[oldCount - 1 - suffixCount] == newLines[newCount - 1 - suffixCount] {
        suffixCount += 1
    }
    // Changed line indices in newText: [firstChanged, lastChanged].
    let firstChanged = prefixCount
    let lastChanged = max(prefixCount, newCount - suffixCount - 1)
    // Walk newText line-by-line using NSString enumeration so offsets are UTF-16 units,
    // matching NSTextStorage expectations and staying safe for all Unicode content.
    let nsNew = newText as NSString
    var rangeStart = 0
    var rangeEnd = nsNew.length
    var currentLine = 0
    var foundStart = false
    var foundEnd = false
    nsNew.enumerateSubstrings(
        in: NSRange(location: 0, length: nsNew.length),
        options: [.byLines, .substringNotRequired]
    ) { _, lineRange, enclosingRange, stop in
        if currentLine == firstChanged {
            rangeStart = lineRange.location
            foundStart = true
        }
        if currentLine == lastChanged {
            rangeEnd = NSMaxRange(enclosingRange)
            foundEnd = true
            stop.pointee = true
        }
        currentLine += 1
    }
    // If firstChanged was never reached (e.g. newText is empty), return empty.
    if !foundStart { return [] }
    // If lastChanged was not reached (change extends to the last line with no trailing newline),
    // rangeEnd stays at nsNew.length which is correct.
    _ = foundEnd
    let length = max(0, rangeEnd - rangeStart)
    return [NSRange(location: rangeStart, length: length)]
}

nonisolated func editorHex(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
}

// MARK: - Editor color palette (no AppKit environment needed; tested in EditorColorPaletteTests)

/// Color set for the code editor and its line-number gutter. Chosen per appearance so the editor
/// doesn't show a near-black background inside a light-mode macOS window.
///
/// Equality is defined by the `isDark` flag because all colors are fully determined by it;
/// this avoids conforming NSColor to Equatable (it doesn't conform natively).
struct EditorColorPalette: Equatable {
    let isDark: Bool
    let background: NSColor
    let text: NSColor
    let insertionPoint: NSColor
    let lineNumberBackground: NSColor
    let lineNumberText: NSColor
    let lineNumberActiveText: NSColor
    let selection: NSColor
    let currentLineBorder: NSColor
    let indentGuide: NSColor
    let indentGuideActive: NSColor

    static func == (lhs: EditorColorPalette, rhs: EditorColorPalette) -> Bool {
        lhs.isDark == rhs.isDark
    }

    /// Choose the palette for the current system appearance. `isDark` is passed as a plain `Bool`
    /// so the helper stays pure (no AppKit environment) and testable without a running NSApp.
    nonisolated static func resolve(isDark: Bool) -> EditorColorPalette {
        if isDark {
            return EditorColorPalette(
                isDark:              true,
                background:          NSColor(red: 0.122, green: 0.122, blue: 0.122, alpha: 1),
                text:                NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
                insertionPoint:      editorHex(0xAEAFAD), // vscode: editorColorRegistry.ts editorCursor.foreground
                lineNumberBackground: NSColor(red: 0.122, green: 0.122, blue: 0.122, alpha: 1),
                lineNumberText:      editorHex(0x6E7681), // vscode: dark_modern.json editorLineNumber.foreground
                lineNumberActiveText: editorHex(0xCCCCCC), // vscode: dark_modern.json editorLineNumber.activeForeground
                selection:           editorHex(0x264F78), // vscode: dark_vs.json editor.selectionBackground
                currentLineBorder:   editorHex(0x282828), // vscode: editorColorRegistry.ts editor.lineHighlightBorder
                indentGuide:         editorHex(0x404040), // vscode: dark_vs.json editorIndentGuide.background1
                indentGuideActive:   editorHex(0x707070)  // vscode: dark_vs.json editorIndentGuide.activeBackground1
            )
        } else {
            return EditorColorPalette(
                isDark:              false,
                background:          NSColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1),
                text:                NSColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1),
                insertionPoint:      .black,
                lineNumberBackground: NSColor(red: 0.91, green: 0.91, blue: 0.91, alpha: 1),
                lineNumberText:      NSColor(red: 0.42, green: 0.44, blue: 0.47, alpha: 1),
                lineNumberActiveText: NSColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1),
                selection:           editorHex(0xADD6FF),
                currentLineBorder:   editorHex(0xEEEEEE),
                indentGuide:         editorHex(0xD3D3D3),
                indentGuideActive:   editorHex(0x939393)
            )
        }
    }
}

private struct FileTabDragModifier: ViewModifier {
    let payload: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}

private struct SidebarMoveDragModifier: ViewModifier {
    let payload: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}

private struct FileOutDragModifier: ViewModifier {
    let absolutePath: String
    let fileTabPayload: String?
    let movePayload: String?

    func body(content: Content) -> some View {
        content.onDrag {
            fileOutItemProvider(
                info: fileOutDragInfo(absolutePath: absolutePath),
                textPayload: fileOutCombinedDragPayload(fileTabPayload: fileTabPayload, movePayload: movePayload)
            )
        }
    }
}

private struct SidebarMoveDropModifier: ViewModifier {
    let enabled: Bool
    let workspaceID: String
    let onDrop: (String) -> Bool
    let isTargeted: (Bool) -> Void

    @ViewBuilder
	    func body(content: Content) -> some View {
	        if enabled {
	            content.dropDestination(for: String.self) { values, _ in
	                guard let raw = values.compactMap(sidebarMoveDragPayloadCandidate(in:)).first,
	                      let payload = SidebarMoveDragPayload.decode(raw),
	                      payload.workspaceID == workspaceID else { return false }
	                return onDrop(payload.relativePath)
	            } isTargeted: { targeted in
                isTargeted(targeted)
            }
        } else {
            content
        }
    }
}

	private extension View {
    func fileTabDragPayload(_ payload: String?) -> some View {
        modifier(FileTabDragModifier(payload: payload))
    }

    func sidebarMoveDragPayload(_ payload: String?) -> some View {
        modifier(SidebarMoveDragModifier(payload: payload))
    }

    func fileOutDragProvider(absolutePath: String, fileTabPayload: String?, movePayload: String?) -> some View {
        modifier(FileOutDragModifier(absolutePath: absolutePath, fileTabPayload: fileTabPayload, movePayload: movePayload))
    }

	func sidebarMoveDropDestination(
        enabled: Bool,
        workspaceID: String,
        onDrop: @escaping (String) -> Bool,
        isTargeted: @escaping (Bool) -> Void
    ) -> some View {
        modifier(SidebarMoveDropModifier(enabled: enabled, workspaceID: workspaceID, onDrop: onDrop, isTargeted: isTargeted))
    }
}

/// Minimal changed range as a UTF-16 NSRange over `old` plus the UTF-16 replacement,
/// found by trimming the common prefix and suffix between `old` and `new`.
/// Extracted from FilesViewModel.minimalEdit so perf/correctness tests can reach it
/// without constructing the full AppKit surface (QA perf guard, CI-gate P2).
func filesMinimalEdit(from old: String, to new: String) -> (location: Int, length: Int, replacement: String) {
    let oldUnits = Array(old.utf16)
    let newUnits = Array(new.utf16)
    var prefix = 0
    let maxPrefix = min(oldUnits.count, newUnits.count)
    while prefix < maxPrefix && oldUnits[prefix] == newUnits[prefix] {
        prefix += 1
    }
    var suffix = 0
    let maxSuffix = min(oldUnits.count, newUnits.count) - prefix
    while suffix < maxSuffix && oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
        suffix += 1
    }
    let location = prefix
    let length = oldUnits.count - prefix - suffix
    let replacement = String(utf16CodeUnits: Array(newUnits[prefix..<(newUnits.count - suffix)]), count: newUnits.count - prefix - suffix)
    return (location, length, replacement)
}

/// Returns the UTF-16 NSRange that covers the basename of `name` (everything
/// before the last dot), so a rename text-field can pre-select the basename
/// and leave the extension intact.
///
/// Rules (UTF-16 units; NSTextField selectedRange must be in UTF-16):
///   - Empty string          -> NSRange(location:0, length:0)
///   - Dotfile (.gitignore)  -> full range (leading dot is not an extension separator)
///   - No extension (Makefile) -> full range
///   - foo.tar.gz            -> covers "foo.tar" (last-dot rule)
///   - Unicode/emoji names   -> lengths computed via NSString so surrogate pairs count correctly
func filesBasenameSelectionRange(for name: String) -> NSRange {
    let ns = name as NSString
    let totalLength = ns.length
    guard totalLength > 0 else { return NSRange(location: 0, length: 0) }
    // Dotfile: name starts with "." and has no other dot -> select all.
    // Also catches pure dotfiles with extensions like ".env.local": the leading
    // dot is part of the stem, so we use last-dot on the suffix after index 1.
    // Find the last dot that is NOT the first character.
    var lastDotUTF16: Int? = nil
    // Scan UTF-16 units; '.' is U+002E, a single UTF-16 unit.
    for i in 1..<totalLength {
        if ns.character(at: i) == UInt16(UInt8(ascii: ".")) {
            lastDotUTF16 = i
        }
    }
    guard let dotIndex = lastDotUTF16 else {
        // No dot after position 0: no extension (or pure dotfile). Select all.
        return NSRange(location: 0, length: totalLength)
    }
    // Basename spans [0, dotIndex).
    return NSRange(location: 0, length: dotIndex)
}

/// Result of evaluating whether an incoming remote edit should be applied
/// immediately or held back to avoid clobbering the user's local draft.
/// Extracted from FilesViewModel so tests can reach it without constructing
/// the full AppKit surface.
enum FilesRemoteUpdateDecision: Equatable {
    /// Apply the remote content to the editor now.
    case apply
    /// The user has unsaved local edits that differ from the incoming remote
    /// content. Preserve the local draft and surface a conflict notice.
    case conflictKeepLocal
}

/// Pure decision function: determines how to handle a remote content update.
///
/// - Parameters:
///   - localDirty:     True when the current draft has unsaved local changes.
///   - localText:      The current draft content in the editor.
///   - remoteText:     The incoming remote content.
///   - lastSyncedText: The last content that was in sync between both sides.
/// - Returns: `.apply` when there is no local-vs-remote conflict;
///            `.conflictKeepLocal` when the local draft diverges from the remote
///            content and must be protected.
func filesRemoteUpdateDecision(
    localDirty: Bool,
    localText: String,
    remoteText: String,
    lastSyncedText: String
) -> FilesRemoteUpdateDecision {
    // No local edits -- safe to apply the remote version unconditionally.
    guard localDirty else { return .apply }
    // Local is dirty but remote content matches local -- no real conflict.
    if remoteText == localText { return .apply }
    // Local draft differs from remote: protect the user's work.
    return .conflictKeepLocal
}

struct FilesRemoteContentUpdate: Equatable {
    let draftText: String
    let renderedText: String
    let pendingRemoteText: String?
    let remoteEditConflict: Bool
}

/// Local FileEditSessionStore open/save/discard echos omit `updated_by_device`.
/// Missing or `mac-local` is this Mac. Any other present device is remote.
func filesEditEventIsRemote(updatedByDevice: String?) -> Bool {
    guard let updatedByDevice, !updatedByDevice.isEmpty else { return false }
    return updatedByDevice != "mac-local"
}

func filesRemoteContentUpdate(
    localDirty: Bool,
    draftText: String,
    renderedText: String,
    remoteText: String,
    lastSyncedText: String
) -> FilesRemoteContentUpdate {
    switch filesRemoteUpdateDecision(
        localDirty: localDirty,
        localText: draftText,
        remoteText: remoteText,
        lastSyncedText: lastSyncedText
    ) {
    case .apply:
        return FilesRemoteContentUpdate(
            draftText: remoteText,
            renderedText: remoteText,
            pendingRemoteText: nil,
            remoteEditConflict: false
        )
    case .conflictKeepLocal:
        return FilesRemoteContentUpdate(
            draftText: draftText,
            renderedText: renderedText,
            pendingRemoteText: remoteText,
            remoteEditConflict: true
        )
    }
}

struct FilesEditClosedUpdate: Equatable {
    let dirtyPaths: Set<String>
    let cachePathToRemove: String?
    let shouldClearActiveSession: Bool
}

func filesEditClosedUpdate(
    currentSessionID: String?,
    currentDirtyPaths: Set<String>,
    closedSessionID: String,
    path: String?
) -> FilesEditClosedUpdate {
    var dirtyPaths = currentDirtyPaths
    if let path {
        dirtyPaths.remove(path)
    }
    return FilesEditClosedUpdate(
        dirtyPaths: dirtyPaths,
        cachePathToRemove: path,
        shouldClearActiveSession: currentSessionID == closedSessionID
    )
}

struct FilesDeleteSelectionUpdate: Equatable {
    let shouldClearSelectedEditor: Bool
    let dirtyPaths: Set<String>
}

func filesDeleteSelectionUpdate(
    selectedPath: String?,
    deletedPaths: [String],
    dirtyPaths: Set<String>
) -> FilesDeleteSelectionUpdate {
    FilesDeleteSelectionUpdate(
        shouldClearSelectedEditor: selectedPath.map { deletedPaths.contains($0) } ?? false,
        dirtyPaths: dirtyPaths.subtracting(deletedPaths)
    )
}

@MainActor
final class FilesViewModel: ObservableObject {
    @Published var currentDirectory = ""
    @Published var entries: [FileEntry] = []
    @Published var selectedEntry: FileEntry?
    /// VS Code-style open file tabs. Explorer activation adds to this list;
    /// selecting another tab keeps each dirty draft alive in `sessionCache`.
    @Published var openTabs: [FileEntry] = []
    @Published var draftText = ""
    @Published var renderedText = ""
    @Published var errorText: String?
    @Published var isLoading = false
    @Published var isDirty = false
    @Published var dirtyPaths: Set<String> = []
    @Published var readerMode = "source"
    // Lazy tree state: which directory rows are currently expanded. The actual per-directory child
    // listings live in `treeStore`, which fetches them on first expand and caches them. Reset
    // whenever the displayed directory changes (P1). `expandedPaths` is the @Published trigger that
    // makes SwiftUI re-render the affected subtree.
    @Published var expandedPaths: Set<String> = []
    @Published var caretLine = 1
    @Published var caretColumn = 1
    private lazy var treeStore = FileTreeStore<FileEntry>(lister: { [weak self] path in
        try self?.listEntries(at: path) ?? []
    })
    @Published var previewURL: URL?
    @Published var syncLabel = "Up to date"
    @Published var syncDetail = ""
    @Published var conflictActive = false
    /// True when a remote edit arrived while the user had unsaved local edits.
    /// The local draft is preserved; the remote version waits in `pendingRemoteText`.
    @Published var remoteEditConflict = false
    /// Non-nil when the most recent explicit Save failed. Shown as an inline
    /// banner instead of replacing the editor with the empty-state (P1 save-fail).
    @Published var saveError: String?

    let surfaceID: SurfaceID
    let workspaceID: WorkspaceID
    let root: String
    weak var router: (any FilesSurfaceRouting)?
    /// Distill-backed inline completion used by the editor. Injected by tests.
    let inlineCompletionProvider: (any InlineCompletionProviding)?
    private var sessionID: String?
    private var draftRevision = 0
    private var lastSyncedText = ""
    private var applying = false
    private var pendingText: String?
    private var suppressEditorChange = false
    private var eventToken: UUID?
    private var sessionCache: [String: EditSessionSnapshot] = [:]
    private var sessionPath: String?
    /// Holds the remote text that arrived during a local-dirty conflict. Discarded
    /// when the user dismisses the banner; applied when they choose "Load Remote".
    private var pendingRemoteText: String?
    /// Interval (seconds) used to coalesce rapid keystrokes before sending a patch.
    /// Named constant so it can be referenced in tests or tuned without a grep.
    private static let editorDebounceInterval: TimeInterval = 0.15
    /// Pending debounce timer; (re)set on each editorChanged call, fired once per burst.
    private var editorDebounceTimer: Timer?
    /// Text captured by the most recent editorChanged call, applied when the timer fires.
    private var pendingDebounceText: String?

    private struct EditSessionSnapshot {
        var sessionID: String
        var draftText: String
        var draftRevision: Int
        var lastSyncedText: String
        var isDirty: Bool
    }

    var selectedPath: String? { selectedEntry?.relativePath }
    var visibleText: String { draftText.isEmpty ? renderedText : draftText }

    init(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        root: String,
        router: any FilesSurfaceRouting,
        inlineCompletionProvider: (any InlineCompletionProviding)? = nil
    ) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.root = root
        self.router = router
        self.inlineCompletionProvider = inlineCompletionProvider
        // Subscribe from the current head, not `nil` (which replays the entire retained
        // backlog into this surface on the main thread). This surface loads its own state
        // explicitly via loadInitialState()/filesStateGet (PERF-MAC_FILES-003).
        // Drop every other kind on the delivery thread (same as PaneTabsView /
        // Agent App `.agentThreadAndQueue`) so token-rate stream events do not
        // hop each open Files tab to main just to hit `receive` default.
        let head = EventBus.shared.currentSeq
        eventToken = EventBus.shared.subscribe(
            since: head,
            filter: .filesSurface
        ) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
    }

    func close() {
        // Flush any buffered keystroke before tearing down: apply the pending draft
        // immediately so no unsaved content is lost when the surface closes.
        editorDebounceTimer?.invalidate()
        editorDebounceTimer = nil
        if let text = pendingDebounceText {
            pendingDebounceText = nil
            if !applying { applyFullDraft(text) }
        }
        if let eventToken { EventBus.shared.unsubscribe(eventToken) }
        if let sessionID { _ = try? router?.filesEditClose(sessionID: sessionID) }
    }

    func loadInitialState() {
        do {
            var initialSelectedPath: String?
            if let state = try router?.filesStateGet(surface: surfaceID).objectValue {
                initialSelectedPath = state["selected_path"]?.stringValue
                let stateDirectory = state["current_directory"]?.stringValue ?? ""
                currentDirectory = initialFilesDirectory(stateDirectory: stateDirectory, selectedPath: initialSelectedPath)
                readerMode = state["reader_mode"]?.stringValue ?? "source"
                dirtyPaths = Self.dirtyPaths(from: state)
                if case .array(let tabs) = state["open_tabs"] ?? .array([]) {
                    restoreOpenTabs(tabs.compactMap(\.stringValue))
                }
            }
            loadDirectory(currentDirectory)
            if let initialSelectedPath,
               let entry = entries.first(where: { !$0.isDirectory && $0.relativePath == initialSelectedPath }) {
                selectedEntry = entry
                openFileInTab(entry)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func loadDirectory(_ relativePath: String) {
        isLoading = true
        errorText = nil
        do {
            let result = try router?.fsWorkspaceList(workspace: workspaceID, path: relativePath)
            entries = mapEntries(result)
            currentDirectory = result?.objectValue?["relative_path"]?.stringValue ?? relativePath
            // Reset the lazy subtree state on navigation: the new directory's children become the
            // top level, and any previously expanded subtree no longer applies (P1).
            expandedPaths = []
            treeStore.setRoots(entries)
            isLoading = false
            _ = try? router?.filesStateUpdate(surface: surfaceID, patch: [
                "current_directory": .string(currentDirectory)
            ], baseRevision: nil, deviceID: "mac-local")
        } catch {
            isLoading = false
            errorText = String(describing: error)
        }
    }

    /// UX-MAC_AGENT-OPEN-SPLIT: reveal a workspace-relative path — select it when
    /// already listed, otherwise navigate to its parent directory and select the
    /// entry there (a directory path opens the directory itself).
    func reveal(relativePath: String) {
        if let known = allKnownEntry(relativePath: relativePath) {
            select(known)
            return
        }
        loadDirectory((relativePath as NSString).deletingLastPathComponent)
        if let entry = entries.first(where: { $0.relativePath == relativePath }) {
            select(entry)
        }
    }

    /// Map a `fsWorkspaceList` result's entries into `FileEntry` rows, attaching drag payloads to
    /// files. Shared by the top-level directory load and the lazy subtree fetch so both produce
    /// identical rows. This keeps the existing security-scoped `fsWorkspaceList` IO unchanged -
    /// only the surrounding tree structure is new (P1).
    private func mapEntries(_ result: JSONValue?) -> [FileEntry] {
        let values = result?.objectValue?["entries"]?.arrayValue ?? []
        var entries: [FileEntry] = []
        entries.reserveCapacity(values.count)
        for value in values {
            guard var entry = FileEntry(value: value) else { continue }
            if !entry.isDirectory {
                entry.dragPayload = FileTabDragPayload.encode(workspaceID: workspaceID, sourceSurfaceID: surfaceID, path: entry.relativePath)
            }
            // All entries (files and directories) can be dragged to move them into a folder.
            entry.moveDragPayload = SidebarMoveDragPayload.encode(workspaceID: workspaceID, relativePath: entry.relativePath)
            entries.append(entry)
        }
        return entries
    }

    /// Fetch the entries directly under `relativePath` (security-scoped `fsWorkspaceList`), mapped
    /// to rows. Used by the lazy subtree fetch.
    private func listEntries(at relativePath: String) throws -> [FileEntry] {
        mapEntries(try router?.fsWorkspaceList(workspace: workspaceID, path: relativePath))
    }

    /// Children of an expanded directory row, fetched lazily the first time the row is expanded and
    /// cached thereafter by `treeStore`; an empty/failed fetch yields `[]` so the row doesn't keep
    /// retrying every redraw (P1).
    func childEntries(for directory: FileEntry) -> [FileEntry] {
        treeStore.children(at: directory.relativePath)
    }

    /// Look up an entry by its relative path across both the top-level entries and any cached
    /// subtree children, so move-drop works even when the dragged item is in an expanded subdir.
    func allKnownEntry(relativePath: String) -> FileEntry? {
        entries.first(where: { $0.relativePath == relativePath })
            ?? treeStore.cachedItem(relativePath: relativePath)
    }

    func entryForSelectionID(_ id: String) -> FileEntry? {
        entries.first(where: { $0.id == id })
            ?? treeStore.cachedItem(id: id)
    }

    func collapseAll() {
        expandedPaths = []
    }

    func isExpanded(_ directory: FileEntry) -> Bool {
        expandedPaths.contains(directory.relativePath)
    }

    /// Toggle a directory row's disclosure. Expanding triggers the lazy child fetch (and caches it);
    /// collapsing only hides the already-fetched subtree. Independent of selection so the triangle
    /// behaves like NSOutlineView disclosure, while row selection still navigates/opens (P1).
    func toggleExpand(_ directory: FileEntry) {
        guard directory.isDirectory else { return }
        if expandedPaths.contains(directory.relativePath) {
            expandedPaths.remove(directory.relativePath)
        } else {
            _ = childEntries(for: directory)
            expandedPaths.insert(directory.relativePath)
        }
    }

    func select(_ entry: FileEntry) {
        selectedEntry = entry
        errorText = nil
        if entry.isDirectory {
            loadDirectory(entry.relativePath)
            return
        }
        openFileInTab(entry)
    }

    /// Explorer activation: open (or focus) a file tab, then load it.
    func openFileInTab(_ entry: FileEntry) {
        if let index = openTabs.firstIndex(where: { $0.id == entry.id }) {
            openTabs[index] = entry
        } else {
            openTabs.append(entry)
            if openTabs.count > Self.maximumOpenTabs {
                let removable = openTabs.firstIndex(where: { !dirtyPaths.contains($0.relativePath) && $0.id != entry.id })
                if let removable { removeTab(at: removable, closeSession: true) }
            }
        }
        loadFile(entry)
        persistOpenTabs()
    }

    /// Activate an already-open tab (the tab bar path).
    func activateTab(_ entry: FileEntry) {
        guard selectedEntry?.id != entry.id else { return }
        selectedEntry = entry
        errorText = nil
        loadFile(entry)
        persistOpenTabs()
    }

    /// Close a tab and activate its right neighbour (or left when it was last).
    func closeTab(_ entry: FileEntry) {
        guard let index = openTabs.firstIndex(where: { $0.id == entry.id }) else { return }
        let wasActive = selectedEntry?.id == entry.id
        removeTab(at: index, closeSession: true)
        if wasActive {
            let next = openTabs.indices.contains(index) ? openTabs[index] : openTabs.last
            if let next {
                selectedEntry = next
                loadFile(next)
            } else {
                selectedEntry = nil
                sessionID = nil
                sessionPath = nil
                setDraft("")
                renderedText = ""
                isDirty = false
            }
        }
        persistOpenTabs()
    }

    private func removeTab(at index: Int, closeSession: Bool) {
        guard openTabs.indices.contains(index) else { return }
        let removed = openTabs.remove(at: index)
        guard closeSession else { return }
        if sessionPath == removed.relativePath, let sessionID {
            _ = try? router?.filesEditClose(sessionID: sessionID)
            self.sessionID = nil
            self.sessionPath = nil
        }
        sessionCache.removeValue(forKey: removed.relativePath)
    }

    func isTabDirty(_ entry: FileEntry) -> Bool {
        if selectedEntry?.id == entry.id { return isDirty }
        return dirtyPaths.contains(entry.relativePath) || sessionCache[entry.relativePath]?.isDirty == true
    }

    private static let maximumOpenTabs = 24

    private func persistOpenTabs() {
        _ = try? router?.filesStateUpdate(surface: surfaceID, patch: [
            "open_tabs": .array(openTabs.map { .string($0.relativePath) })
        ], baseRevision: nil, deviceID: "mac-local")
    }

    /// Rebuild tabs from persisted relative paths without listing their
    /// directories. Identity (kind/language) is refreshed when the tab loads.
    private func restoreOpenTabs(_ paths: [String]) {
        openTabs = paths.prefix(Self.maximumOpenTabs).compactMap { relative in
            guard !relative.isEmpty else { return nil }
            return FileEntry.placeholder(relativePath: relative, root: root)
        }
    }

    func selectIfNeeded(_ entry: FileEntry) {
        guard selectedEntry?.id != entry.id else { return }
        select(entry)
    }

    func loadFile(_ entry: FileEntry) {
        snapshotCurrentSession()
        // Close the previous clean session now that it has been snapshotted (or there was nothing
        // to snapshot). Dirty sessions stay open so the snapshotted sessionID remains valid for a
        // later restore. This bounds the number of live host edit sessions to (dirty open files + 1).
        if shouldClosePriorEditSession(prevPath: sessionPath, prevIsDirty: isDirty, newPath: entry.relativePath),
           let prevSessionID = sessionID {
            _ = try? router?.filesEditClose(sessionID: prevSessionID)
            sessionID = nil
        }
        do {
            _ = try router?.filesStateUpdate(surface: surfaceID, patch: [
                "selected_path": .string(entry.relativePath),
                "reader_mode": .string(readerMode)
            ], baseRevision: nil, deviceID: "mac-local")
            previewURL = URL(fileURLWithPath: entry.path)
            if entry.isEditable {
                if let cached = sessionCache[entry.relativePath], cached.isDirty {
                    restoreSession(cached)
                } else {
                    let opened = try router?.filesEditOpen(surface: surfaceID, path: entry.relativePath)
                    applyEditPayload(opened?.objectValue ?? [:], remote: false)
                }
                sessionPath = entry.relativePath
            } else {
                sessionID = nil
                sessionPath = nil
                isDirty = false
                let read = try router?.fsWorkspaceRead(workspace: workspaceID, path: entry.relativePath, maxBytes: WorkspaceFileLimits.readBytes)
                let readObject = read?.objectValue ?? [:]
                let resolved = readObject["identity"]?.objectValue.flatMap(entry.replacingIdentity)
                if let resolved {
                    selectedEntry = resolved
                }
                if let resolved, resolved.isEditable {
                    if let cached = sessionCache[entry.relativePath], cached.isDirty {
                        restoreSession(cached)
                    } else {
                        let opened = try router?.filesEditOpen(surface: surfaceID, path: entry.relativePath)
                        applyEditPayload(opened?.objectValue ?? [:], remote: false)
                    }
                    sessionPath = entry.relativePath
                } else {
                    let content = readObject["content"]?.stringValue ?? ""
                    setDraft(content)
                    renderedText = content
                }
            }
            setSyncLabel("Up to date", revision: draftRevision)
        } catch {
            logFailure("open", error: error)
            errorText = String(describing: error)
        }
    }

    func editorChanged(_ value: String) {
        guard !suppressEditorChange, sessionID != nil, value != lastSyncedText else { return }
        // Capture the latest text so the timer always applies the final state of the burst.
        pendingDebounceText = value
        // Cancel any in-flight timer and reschedule; the last keystroke wins.
        editorDebounceTimer?.invalidate()
        editorDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.editorDebounceInterval,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.editorDebounceTimer = nil
            guard let text = self.pendingDebounceText else { return }
            self.pendingDebounceText = nil
            if self.applying {
                self.pendingText = text
                return
            }
            self.applyFullDraft(text)
        }
    }

    func save() {
        guard let sessionID else { return }
        do {
            let result = try router?.filesEditSave(sessionID: sessionID)
            saveError = nil
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            logFailure("save", error: error)
            // Show save failure as a dismissible banner (P1: do NOT replace the
            // editor with the empty-state, so the unsaved draft remains visible).
            saveError = String(describing: error)
        }
    }

    func dismissSaveError() { saveError = nil }

    func discard() {
        guard let sessionID else { return }
        do {
            let result = try router?.filesEditDiscard(sessionID: sessionID)
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            logFailure("discard", error: error)
            errorText = String(describing: error)
        }
    }

    func createFile(named rawName: String) {
        guard let path = newFileTargetPath(parent: currentDirectory, rawName: rawName) else { return }
        do {
            let result = try router?.fsWorkspaceCreateFile(workspace: workspaceID, path: path, content: "")
            let created = result.flatMap(FileEntry.init(value:))
            loadDirectory(currentDirectory)
            if let created {
                selectedEntry = created
                openFileInTab(created)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func createFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existingNames = Set(entries.map(\.name))
        let path = newFolderTargetPath(parent: currentDirectory, name: name, existingNames: existingNames)
        do {
            _ = try router?.fsWorkspaceCreateDirectory(workspace: workspaceID, path: path)
            loadDirectory(currentDirectory)
        } catch {
            errorText = String(describing: error)
        }
    }

    /// Move `entry` into `destinationDirectory`. Validates that the move does not create a cycle
    /// (moving a dir into itself or a descendant) before calling the router. The `root` param is
    /// the workspace's absolute root path, used only for the cycle check.
    func moveEntry(_ entry: FileEntry, intoDirWithPath destRelativePath: String) {
        let absRoot = root
        // Build absolute paths for the cycle/workspace check.
        let absSrc = entry.path
        let absDst = destRelativePath.isEmpty
            ? absRoot
            : (absRoot as NSString).appendingPathComponent(destRelativePath)
        guard validateMove(src: absSrc, dstDir: absDst, workspaceRoot: absRoot) else {
            errorText = "Cannot move a folder into itself or a descendant."
            return
        }
        if selectedEntry?.id == entry.id {
            closeSessionIfSelected(path: entry.relativePath)
        }
        do {
            _ = try router?.fsWorkspaceMoveItem(workspace: workspaceID, sourcePath: entry.relativePath, destinationDirectoryPath: destRelativePath)
            if selectedEntry?.id == entry.id {
                selectedEntry = nil
                setDraft("")
                renderedText = ""
                isDirty = false
            }
            loadDirectory(currentDirectory)
        } catch {
            errorText = String(describing: error)
        }
    }

    func rename(_ entry: FileEntry, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        closeSessionIfSelected(path: entry.relativePath)
        do {
            let result = try router?.fsWorkspaceRename(workspace: workspaceID, path: entry.relativePath, newName: name)
            let renamed = result.flatMap(FileEntry.init(value:))
            loadDirectory(currentDirectory)
            if let renamed, let tabIndex = openTabs.firstIndex(where: { $0.id == entry.id }) {
                openTabs[tabIndex] = renamed
                persistOpenTabs()
            }
            if selectedEntry?.id == entry.id, let renamed {
                selectedEntry = renamed
                loadFile(renamed)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func delete(_ entries: [FileEntry]) {
        let relativePaths = entries.map(\.relativePath)
        guard !relativePaths.isEmpty else { return }
        let update = filesDeleteSelectionUpdate(
            selectedPath: selectedPath,
            deletedPaths: relativePaths,
            dirtyPaths: dirtyPaths
        )
        if update.shouldClearSelectedEditor, let selectedPath {
            closeSessionIfSelected(path: selectedPath)
            selectedEntry = nil
            setDraft("")
            renderedText = ""
            isDirty = false
        }
        let deletedIDs = Set(entries.map(\.id))
        openTabs.removeAll { deletedIDs.contains($0.id) }
        persistOpenTabs()
        let urls = recycleURLs(forAbsolutePaths: entries.map(\.path))
        dirtyPaths = update.dirtyPaths
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.errorText = String(describing: error)
                } else {
                    self.loadDirectory(self.currentDirectory)
                }
            }
        }
    }

    func openInNewTab(_ entry: FileEntry) {
        guard !entry.isDirectory else { return }
        do {
            _ = try router?.filesOpenTab(workspace: workspaceID, sourceSurface: surfaceID, paneID: nil, path: entry.relativePath)
        } catch {
            errorText = String(describing: error)
        }
    }

    func splitFileTab(path: String, direction: SplitDirection) {
        do {
            _ = try router?.filesSplitTab(workspace: workspaceID, sourceSurface: surfaceID, paneID: nil, direction: direction, path: path)
        } catch {
            errorText = String(describing: error)
        }
    }

	    func handleFileDropPayload(_ rawPayload: String, location: CGPoint, size: CGSize) -> Bool {
	        guard let path = fileTabDropPath(rawPayload: rawPayload, workspaceID: workspaceID) else { return false }
	        splitFileTab(path: path, direction: fileDropSplitDirection(location: location, size: size))
	        return true
	    }

    func insertText(_ text: String) {
        draftText += text
        editorChanged(draftText)
    }

    func setReaderMode(_ mode: String) {
        guard ["source", "preview", "split"].contains(mode) else { return }
        readerMode = mode
        _ = try? router?.filesStateUpdate(surface: surfaceID, patch: [
            "reader_mode": .string(mode)
        ], baseRevision: nil, deviceID: "mac-local")
    }

    private func applyFullDraft(_ newText: String) {
        guard let sessionID else { return }
        let delta = Self.minimalEdit(from: lastSyncedText, to: newText)
        applying = true
        do {
            let result = try router?.filesEditApplyPatch(
                sessionID: sessionID,
                baseDraftRevision: draftRevision,
                rangeLocation: delta.location,
                rangeLength: delta.length,
                replacement: delta.replacement,
                deviceID: "mac-local"
            )
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            logFailure("patch", error: error)
            errorText = String(describing: error)
        }
        applying = false
        if let pendingText, pendingText != lastSyncedText {
            self.pendingText = nil
            applyFullDraft(pendingText)
        } else {
            pendingText = nil
        }
    }

    /// Delegates to the module-level filesMinimalEdit free function so the
    /// algorithm is unit-testable without constructing the full AppKit surface.
    static func minimalEdit(from old: String, to new: String) -> (location: Int, length: Int, replacement: String) {
        filesMinimalEdit(from: old, to: new)
    }

    /// Incremented at the top of `receive` so tests can prove stream kinds
    /// never hop to main. Production ignores it.
    var eventReceiveCountForTests = 0

    private func receive(_ event: EventBus.Event) {
        eventReceiveCountForTests += 1
        guard let payload = event.payload.objectValue else { return }
        // Kinds must stay under EventStreamFilter.filesSurface prefixes.
        switch event.kind {
        case "files.state.updated":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString,
                  let state = payload["state"]?.objectValue else { return }
            currentDirectory = state["current_directory"]?.stringValue ?? currentDirectory
            readerMode = state["reader_mode"]?.stringValue ?? readerMode
            dirtyPaths = Self.dirtyPaths(from: state)
            isDirty = selectedPath.map { dirtyPaths.contains($0) } ?? isDirty
            setSyncLabel(isDirty ? "Unsaved" : "Up to date", revision: state["revision"]?.intValue ?? 0)
        case "files.edit.opened", "files.edit.patch_applied", "files.edit.saved", "files.edit.discarded":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString else { return }
            applyEditPayload(
                payload,
                remote: filesEditEventIsRemote(updatedByDevice: payload["updated_by_device"]?.stringValue)
            )
        case "files.edit.conflict":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString else { return }
            conflictActive = true
            filesLog.notice("files.conflict kind=\(self.selectedEntry?.kind ?? "none", privacy: .public) size=\(sizeBucket(self.selectedEntry?.size ?? -1), privacy: .public)")
        case "files.edit.closed":
            // A session closed elsewhere (e.g. another device or a server-side cleanup) must clear
            // our local session/dirty state for that path; otherwise we'd keep editing against a
            // session the host no longer has (QA-MAC_FILES-007).
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString,
                  let closedID = payload["session_id"]?.stringValue else { return }
            let update = filesEditClosedUpdate(
                currentSessionID: sessionID,
                currentDirtyPaths: dirtyPaths,
                closedSessionID: closedID,
                path: payload["path"]?.stringValue
            )
            dirtyPaths = update.dirtyPaths
            if let path = update.cachePathToRemove {
                sessionCache.removeValue(forKey: path)
            }
            if update.shouldClearActiveSession {
                sessionID = nil
                sessionPath = nil
                isDirty = false
            }
        default:
            break
        }
    }

    // MARK: - Remote update decision

    /// Apply the remote content that arrived during a conflict, discarding the
    /// local draft. Called when the user explicitly taps "Load Remote".
    func loadRemoteEdit() {
        guard let remote = pendingRemoteText else { return }
        pendingRemoteText = nil
        remoteEditConflict = false
        setDraft(remote)
        renderedText = remote
    }

    /// Dismiss the remote-edit conflict notice and keep the local draft.
    /// The pending remote text is dropped -- it is no longer needed.
    func dismissRemoteEditConflict() {
        pendingRemoteText = nil
        remoteEditConflict = false
    }

    private func applyEditPayload(_ payload: [String: JSONValue], remote: Bool) {
        conflictActive = false
        // A non-remote payload means a local open/save/discard -- clear any
        // stale remote-conflict notice so it does not carry over to the new file.
        if !remote {
            remoteEditConflict = false
            pendingRemoteText = nil
        }
        if let id = payload["session_id"]?.stringValue { sessionID = id }
        if let revision = payload["draft_revision"]?.intValue { draftRevision = revision }
        if let dirty = payload["dirty"]?.boolValue {
            isDirty = dirty
            if let path = payload["path"]?.stringValue {
                if dirty {
                    dirtyPaths.insert(path)
                } else {
                    dirtyPaths.remove(path)
                    sessionCache.removeValue(forKey: path)
                }
            }
        }
        if let content = payload["content"]?.stringValue {
            if remote {
                let update = filesRemoteContentUpdate(
                    localDirty: isDirty,
                    draftText: draftText,
                    renderedText: renderedText,
                    remoteText: content,
                    lastSyncedText: lastSyncedText
                )
                remoteEditConflict = update.remoteEditConflict
                pendingRemoteText = update.pendingRemoteText
                if update.remoteEditConflict {
                    // Preserve the local draft. Park the remote version so the user
                    // can load it explicitly via the conflict banner ("Load Remote").
                    renderedText = update.renderedText
                } else {
                    setDraft(update.draftText)
                    renderedText = update.renderedText
                }
            } else if draftText != content {
                setDraft(content)
                renderedText = content
            } else {
                lastSyncedText = content
                renderedText = content
            }
        }
        if remote && !remoteEditConflict {
            setSyncLabel("Edited on another device", revision: draftRevision)
        } else if remote && remoteEditConflict {
            setSyncLabel("Remote changes held -- local edits preserved", revision: draftRevision)
        } else if isDirty {
            setSyncLabel("Unsaved", revision: draftRevision)
        } else {
            setSyncLabel("Saved", revision: draftRevision)
        }
    }

    /// Human-readable sync status with the internal revision kept only as a tooltip detail
    /// (UX-MAC_FILES-006).
    private func setSyncLabel(_ label: String, revision: Int) {
        syncLabel = label
        syncDetail = "Revision \(revision)"
    }

    /// Record an operation failure with its RPC error code, file kind, and a coarse size bucket -
    /// no paths or contents - so flaky save/conflict/decode reports are reproducible (QA-MAC_FILES-008).
    private func logFailure(_ operation: String, error: Error) {
        let kind = selectedEntry?.kind ?? "none"
        let bucket = sizeBucket(selectedEntry?.size ?? -1)
        if let rpc = error as? JSONRPCError {
            filesLog.error("files.\(operation, privacy: .public) failed code=\(rpc.code, privacy: .public) kind=\(kind, privacy: .public) size=\(bucket, privacy: .public)")
        } else {
            filesLog.error("files.\(operation, privacy: .public) failed kind=\(kind, privacy: .public) size=\(bucket, privacy: .public)")
        }
    }

    private static func dirtyPaths(from state: [String: JSONValue]) -> Set<String> {
        guard case .array(let values) = state["dirty_paths"] ?? .array([]) else { return [] }
        return Set(values.compactMap(\.stringValue))
    }

    private func setDraft(_ text: String) {
        suppressEditorChange = true
        draftText = text
        lastSyncedText = text
        suppressEditorChange = false
    }

    private func closeSessionIfSelected(path: String) {
        guard selectedPath == path, let sessionID else { return }
        _ = try? router?.filesEditClose(sessionID: sessionID)
        self.sessionID = nil
        if sessionPath == path { sessionPath = nil }
        sessionCache.removeValue(forKey: path)
    }

    /// Persist the currently open edit session so reselecting its path restores the draft
    /// instead of reopening from disk (UX-MAC_FILES-004/005). Keyed by the live session's
    /// own path (`sessionPath`), not `selectedPath`, since selection is updated before loadFile.
    private func snapshotCurrentSession() {
        guard let sessionID, let path = sessionPath else { return }
        sessionCache[path] = EditSessionSnapshot(
            sessionID: sessionID,
            draftText: draftText,
            draftRevision: draftRevision,
            lastSyncedText: lastSyncedText,
            isDirty: isDirty
        )
    }

    private func restoreSession(_ snapshot: EditSessionSnapshot) {
        sessionID = snapshot.sessionID
        draftRevision = snapshot.draftRevision
        isDirty = snapshot.isDirty
        setDraft(snapshot.draftText)
        lastSyncedText = snapshot.lastSyncedText
        renderedText = snapshot.draftText
        setSyncLabel(isDirty ? "Unsaved" : "Up to date", revision: draftRevision)
    }
}

/// Shared Files UI. Agent App panes and Studio bot home both host this view.
private enum VSCodeTheme {
    static let sideBarBackground = color(0x181818)
    static let editorBackground = color(0x1F1F1F)
    static let tabsContainer = color(0x181818)
    static let activeTab = color(0x1F1F1F)
    static let inactiveTab = color(0x181818)
    static let tabActiveBorderTop = color(0x0078D4)
    static let border = color(0x2B2B2B)
    static let listHover = color(0x2A2D2E)
    static let listActiveSelection = color(0x37373D)
    static let listFocusedSelection = color(0x04395E)
    static let focusBorder = color(0x0078D4)
    static let foreground = color(0xCCCCCC)
    static let inactiveForeground = color(0x9D9D9D)
    static let sectionHeader = color(0xCCCCCC)
    static let indentGuide = color(0x585858)
    static let dirty = color(0xFFFFFF)
    static let modifiedText = color(0xE2C08D)
    static let statusBar = color(0x181818)
    static let statusBarForeground = color(0xCCCCCC)
    static let statusBarBorder = color(0x2B2B2B)
    static let inputBackground = color(0x313131)
    static let inputBorder = color(0x3C3C3C)

    static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// VS Code Dark Modern file-type colors keyed by extension (case-insensitive).
func fileIconColorHex(for filename: String) -> UInt32 {
    switch (filename as NSString).pathExtension.lowercased() {
    case "swift": return 0xF05138
    case "ts", "tsx": return 0x3178C6
    case "js", "jsx": return 0xF1DD3F
    case "json": return 0xCBCB41
    case "md": return 0x519ABA
    case "py": return 0x3572A5
    case "go": return 0x00ADD8
    case "rs": return 0xDEA584
    case "html": return 0xE44D26
    case "css", "scss": return 0x42A5F5
    case "sh", "zsh", "bash": return 0x89E051
    case "yml", "yaml": return 0xCB171E
    default: return 0x9D9D9D
    }
}

/// Status bar label for a language id. nil or empty means plain text.
func languageDisplayName(_ language: String?) -> String {
    let id = (language ?? "").lowercased()
    switch id {
    case "swift": return "Swift"
    case "typescript": return "TypeScript"
    case "javascript": return "JavaScript"
    case "python": return "Python"
    case "go": return "Go"
    case "rust": return "Rust"
    case "json": return "JSON"
    case "markdown": return "Markdown"
    case "html": return "HTML"
    case "css": return "CSS"
    case "shell script", "shellscript", "shell", "bash", "zsh", "sh": return "Shell Script"
    case "yaml", "yml": return "YAML"
    case "", "text", "plaintext", "plain text": return "Plain Text"
    default: return language.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Plain Text"
    }
}

/// 1-based line and column of a UTF-16 caret offset.
func caretLineColumn(text: String, utf16Offset: Int) -> (line: Int, column: Int) {
    let offsets = buildLineStartOffsets(text: text)
    let index = lineIndex(forCharOffset: utf16Offset, in: offsets)
    let lineStart = offsets.isEmpty ? 0 : offsets[index]
    return (index + 1, utf16Offset - lineStart + 1)
}

struct FilesSurfaceRoot: View {
    @ObservedObject var model: FilesViewModel
    @AppStorage("files.sidebar.width.v2") private var sidebarWidth: Double = 260
    @AppStorage("files.sidebar.intent.v1") private var sidebarIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @AppStorage("files.sidebar.showHidden.v1") private var showHidden = false
    @State private var sidebarVisible = true
    @State private var lastAutomaticSidebarChange: TimeInterval?
    @State private var selectedFileIDs: Set<String> = []
    @State private var pathInput = ""
    @State private var confirmDiscard = false
    @State private var showNewFileDialog = false
    @State private var newFileName = ""
    @State private var showNewFolderDialog = false
    @State private var newFolderName = ""
    @FocusState private var newFolderFieldFocused: Bool
    @State private var dropTargetedFolderPath: String? = nil
    @State private var renamingEntry: FileEntry?
    @State private var renameText = ""
    @State private var deleteTargets: [FileEntry] = []
    @State private var confirmDelete = false
    @State private var pathInvalid = false
    @State private var dropTargeted = false
    @FocusState private var newFileFieldFocused: Bool
    @State private var nameFilter = ""
    @State private var explorerHovered = false
    @State private var hoveredRowID: String?
    @State private var hoveredTabID: String?
    @State private var hoveredCloseTabID: String?
    @FocusState private var nameFilterFocused: Bool
    // PERF: visibleEntries filters on every SwiftUI body evaluation (scroll, selection, etc.).
    // Cache last result and only recompute when entries, showHidden, or nameFilter changes —
    // mirrors SidebarView.filteredWorkspacesCache, avoids O(N) filter on transient body passes.
    @State private var visibleEntriesCache: [FileEntry] = []
    @State private var visibleEntriesCacheKey: (count: Int, showHidden: Bool, query: String) = (0, false, "")
    @State private var visibleEntriesSource: [FileEntry] = []

    // Preview HTML cache -- avoids recomputing MarkdownSurface.renderHTML / highlightedHTML
    // on every SwiftUI body pass. Seeded immediately on .onAppear; subsequent changes are
    // debounced by previewDebounceInterval so rapid typing does not hammer the renderer.
    private static let previewDebounceInterval: TimeInterval = 0.2
    @State private var cachedPreviewHTML = ""
    @State private var previewDebounceTimer: Timer? = nil

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: sidebarWidth)
                    DSResizeDivider(axis: .vertical, help: "Resize file list") { delta in
                        sidebarWidth = min(560, max(240, sidebarWidth + Double(delta)))
                    }
                }
                reader
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { applyAdaptiveSidebar(width: proxy.size.width, event: .structural) }
            .onChange(of: proxy.size.width) { width in
                applyAdaptiveSidebar(width: width, event: .resize)
            }
            .onChange(of: model.readerMode) { _ in
                applyAdaptiveSidebar(width: proxy.size.width, event: .structural)
            }
            statusBar
            }
        }
        .background(VSCodeTheme.editorBackground)
        .foregroundStyle(DS.Palette.text)
        .alert("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { model.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reverts the current draft to the last saved version.")
        }
        .alert("New File", isPresented: $showNewFileDialog) {
            TextField("File name", text: $newFileName)
                .focused($newFileFieldFocused)
                .onSubmit { createNewFile() }
                .accessibilityIdentifier("files.newFile.field")
            Button("Create") { createNewFile() }
                .accessibilityIdentifier("files.newFile.create")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.currentDirectory.isEmpty ? "Create in workspace root." : "Create in \(model.currentDirectory).")
        }
        // Focus the name field as soon as the New File dialog appears so keyboard users can
        // type immediately without clicking first (UX-MAC_FILES-001).
        .onChange(of: showNewFileDialog) { presented in
            if presented { newFileFieldFocused = true }
        }
        .alert("New Folder", isPresented: $showNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
                .focused($newFolderFieldFocused)
                .onSubmit { createNewFolder() }
                .accessibilityIdentifier("files.newFolder.field")
            Button("Create") { createNewFolder() }
                .accessibilityIdentifier("files.newFolder.create")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.currentDirectory.isEmpty ? "Create in workspace root." : "Create in \(model.currentDirectory).")
        }
        .onChange(of: showNewFolderDialog) { presented in
            if presented { newFolderFieldFocused = true }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )) {
            TextField("File name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renamingEntry = nil }
        }
        .alert(deleteTitle, isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteTargets.count == 1 ? deleteTargets[0].relativePath : "\(deleteTargets.count) selected items will be moved to the Trash.")
        }
        .onAppear { pathInput = displayPath }
        .onChange(of: model.currentDirectory) { _ in
            pathInput = displayPath
            selectedFileIDs = []
            updateVisibleEntriesCacheIfNeeded()
        }
        .onChange(of: model.entries) { _ in updateVisibleEntriesCacheIfNeeded() }
        .onChange(of: showHidden) { _ in updateVisibleEntriesCacheIfNeeded() }
        .onChange(of: nameFilter) { _ in updateVisibleEntriesCacheIfNeeded() }
        .onAppear { updateVisibleEntriesCacheIfNeeded() }
        .onChange(of: selectedFileIDs) { ids in
            guard ids.count == 1,
                  let id = ids.first,
                  let entry = model.entryForSelectionID(id) else { return }
            model.selectIfNeeded(entry)
        }
        // Seed cachedPreviewHTML immediately on first appear so the initial render
        // is not blank. Subsequent changes go through the debounce path.
        .onAppear {
            cachedPreviewHTML = computePreviewHTML(markdown: isMarkdownEntry)
        }
        // Debounce preview recompute when the draft text changes (rapid typing path).
        .onChange(of: model.draftText) { _ in
            schedulePreviewRecompute(markdown: isMarkdownEntry)
        }
        // Immediately recompute when a different file is selected so the preview
        // switches to the new file without a 200ms blank frame.
        .onChange(of: model.selectedEntry) { _ in
            previewDebounceTimer?.invalidate()
            previewDebounceTimer = nil
            cachedPreviewHTML = computePreviewHTML(markdown: isMarkdownEntry)
        }
        // Tear down any pending debounce timer when the view is removed.
        .onDisappear {
            previewDebounceTimer?.invalidate()
            previewDebounceTimer = nil
        }
    }

    // True when the currently selected entry should be rendered as Markdown HTML.
    private var isMarkdownEntry: Bool {
        model.selectedEntry?.kind == "markdown"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("EXPLORER")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(VSCodeTheme.inactiveForeground)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Toggle("Show Hidden Files", isOn: $showHidden)
                        .accessibilityIdentifier("files.showHidden.toggle")
                    Divider()
                    Button("Hide file sidebar") {
                        sidebarIntent = .forcedHidden
                        sidebarVisible = false
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(VSCodeTheme.inactiveForeground)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
            .padding(.horizontal, 10)
            .frame(height: 35)
            HStack(spacing: 2) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text((model.root as NSString).lastPathComponent.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if explorerHovered {
                    explorerAction("doc.badge.plus", label: "New file", id: "files.newFile.button") {
                        newFileName = ""
                        showNewFileDialog = true
                    }
                    explorerAction("folder.badge.plus", label: "New folder", id: "files.newFolder.button") {
                        newFolderName = ""
                        showNewFolderDialog = true
                    }
                    explorerAction("arrow.clockwise", label: "Refresh", id: "files.refresh.button") {
                        model.loadDirectory(model.currentDirectory)
                    }
                    explorerAction("rectangle.compress.vertical", label: "Collapse folders", id: "files.collapseAll.button") {
                        model.collapseAll()
                    }
                }
            }
            .foregroundStyle(VSCodeTheme.sectionHeader)
            .padding(.horizontal, 4)
            .frame(height: 22)
            TextField("Filter files\u{2026}", text: $nameFilter)
                .textFieldStyle(.plain)
                .focused($nameFilterFocused)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(VSCodeTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(nameFilterFocused ? VSCodeTheme.focusBorder : VSCodeTheme.inputBorder, lineWidth: 1)
                )
                .foregroundStyle(VSCodeTheme.foreground)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .accessibilityLabel("Filter files by name")
                .accessibilityIdentifier("files.nameFilter.field")
                .onChange(of: model.currentDirectory) { _ in nameFilter = "" }
            TextField("Path", text: $pathInput)
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundStyle(pathInvalid ? DS.Palette.danger : VSCodeTheme.inactiveForeground)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .onSubmit { submitPath() }
                .help("Type a workspace path and press Return")
                .accessibilityLabel("Workspace path")
                .accessibilityIdentifier("files.path.field")
            breadcrumb
            List(selection: $selectedFileIDs) {
                if !model.currentDirectory.isEmpty {
                    Button {
                        navigateToParent()
                    } label: {
                        treeRow(icon: "arrow.turn.up.left", iconColor: VSCodeTheme.inactiveForeground, name: "..", depth: 0) {
                            Color.clear.frame(width: 16, height: 22)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    // Cmd+Up navigates up a level for keyboard users, since the ".." row is not part
                    // of the List selection set and arrow keys never reach it (UX-MAC_FILES-012).
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Go to parent folder (⌘↑)")
                    .accessibilityIdentifier("files.parent.button")
                }
                treeRows(visibleEntries, depth: 0)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VSCodeTheme.sideBarBackground)
            .accessibilityIdentifier("files.sidebar.list")
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("files.sidebar.loading")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VSCodeTheme.sideBarBackground)
        .foregroundStyle(VSCodeTheme.foreground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(VSCodeTheme.border).frame(width: 1)
        }
        .onHover { explorerHovered = $0 }
    }

    private func explorerAction(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(VSCodeTheme.inactiveForeground)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var displayPath: String {
        guard !model.currentDirectory.isEmpty else { return model.root }
        return (model.root as NSString).appendingPathComponent(model.currentDirectory)
    }

    // Dotfiles are hidden unless the user opts in via the sidebar toggle (IMP-MAC_FILES-014).
    // Name filter further narrows the visible set when the user types in the filter field.
    // PERF: avoid O(N) filter on every transient body (scroll/selection) — cache last result.
    // `onChange` of entries/showHidden/nameFilter keeps cache fresh; body fast-path reuses it.
    // Count-only key is fast, but a rename keeps count same — also check source equality to avoid stale.
    private var visibleEntries: [FileEntry] {
        let key = (count: model.entries.count, showHidden: showHidden, query: nameFilter)
        if !visibleEntriesCache.isEmpty && key.count == visibleEntriesCacheKey.count && key.showHidden == visibleEntriesCacheKey.showHidden && key.query == visibleEntriesCacheKey.query && visibleEntriesSource == model.entries {
            return visibleEntriesCache
        }
        return visibleFileEntries(model.entries, showHidden: showHidden, query: nameFilter, isHidden: \.isHidden)
    }

    private func updateVisibleEntriesCacheIfNeeded() {
        let key = (count: model.entries.count, showHidden: showHidden, query: nameFilter)
        if !visibleEntriesCache.isEmpty && key.count == visibleEntriesCacheKey.count && key.showHidden == visibleEntriesCacheKey.showHidden && key.query == visibleEntriesCacheKey.query && visibleEntriesSource == model.entries {
            return
        }
        visibleEntriesCache = visibleFileEntries(model.entries, showHidden: showHidden, query: nameFilter, isHidden: \.isHidden)
        visibleEntriesCacheKey = key
        visibleEntriesSource = model.entries
    }

    private func visibleChildren(of directory: FileEntry) -> [FileEntry] {
        let children = model.childEntries(for: directory)
        return visibleFileEntries(children, showHidden: showHidden, query: "", isHidden: \.isHidden)
    }

    // Recursive tree renderer (P1): each row gets a disclosure triangle when it is a directory, and
    // its children are emitted indented and lazily - `model.childEntries` only fetches on first
    // expand. Selection/open/drag/dirty affordances are unchanged from the old flat row; only the
    // leading disclosure control and indentation are new.
    // Returns AnyView to break the self-referential opaque return type a directly recursive
    // @ViewBuilder would otherwise produce.
    private func treeRows(_ entries: [FileEntry], depth: Int) -> some View {
        ForEach(entries) { entry in
            entryRow(entry, depth: depth)
            if entry.isDirectory && model.isExpanded(entry) {
                AnyView(treeRows(visibleChildren(of: entry), depth: depth + 1))
            }
        }
    }

    private func entryRow(_ entry: FileEntry, depth: Int) -> some View {
        let isDropTarget = dropTargetedFolderPath == entry.relativePath
        let isExpanded = entry.isDirectory && model.isExpanded(entry)
        return treeRow(
            icon: entry.isDirectory ? (isExpanded ? "folder.fill" : "folder") : entry.icon,
            iconColor: VSCodeTheme.color(entry.isDirectory ? 0xDCB67A : fileIconColorHex(for: entry.name)),
            name: entry.name,
            depth: depth,
            active: model.selectedEntry?.id == entry.id,
            focused: selectedFileIDs.contains(entry.id),
            hovered: hoveredRowID == entry.id,
            dirty: model.dirtyPaths.contains(entry.relativePath),
            dirtyPath: entry.relativePath
        ) {
            if entry.isDirectory {
                Button {
                    model.toggleExpand(entry)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VSCodeTheme.inactiveForeground)
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse folder" : "Expand folder")
                .accessibilityIdentifier("files.disclosure.\(entry.relativePath)")
            } else {
                Color.clear.frame(width: 16, height: 22)
            }
        }
        .overlay {
            if isDropTarget {
                Rectangle()
                    .stroke(VSCodeTheme.focusBorder, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("files.moveDropIndicator.\(entry.relativePath)")
            }
        }
        .onTapGesture {
            selectedFileIDs = [entry.id]
            model.selectIfNeeded(entry)
        }
        .onHover { inside in
            if inside {
                hoveredRowID = entry.id
            } else if hoveredRowID == entry.id {
                hoveredRowID = nil
            }
        }
        .tag(entry.id)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .contextMenu { fileContextMenu(for: entry) }
	        .fileTabDragPayload(entry.dragPayload)
	        // Any entry can be dragged to move it. Directories also accept drops.
	        .sidebarMoveDragPayload(entry.moveDragPayload)
	        .fileOutDragProvider(absolutePath: entry.path, fileTabPayload: entry.dragPayload, movePayload: entry.moveDragPayload)
	        .sidebarMoveDropDestination(
            enabled: entry.isDirectory,
            workspaceID: model.workspaceID.value.uuidString,
            onDrop: { relativePath in
                guard let src = model.entries.first(where: { $0.relativePath == relativePath })
                    ?? model.allKnownEntry(relativePath: relativePath) else { return false }
                model.moveEntry(src, intoDirWithPath: entry.relativePath)
                return true
            },
            isTargeted: { targeted in
                dropTargetedFolderPath = targeted ? entry.relativePath : nil
            }
        )
        .help(entry.relativePath.isEmpty ? entry.name : entry.relativePath)
        .accessibilityIdentifier("files.row.\(entry.relativePath)")
    }

    // Language badge, size, and modified-ago for the selected text file so users get context
    // that previously only appeared in the binary view (UX-MAC_FILES-007).
    private func fileMetaSubtitle(_ entry: FileEntry) -> String? {
        var parts: [String] = []
        if let language = entry.language, !language.isEmpty {
            parts.append(language)
        } else if !entry.kind.isEmpty {
            parts.append(entry.kind)
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        if let modified = entry.modifiedAt {
            let date = Date(timeIntervalSince1970: modified)
            parts.append(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // Map developer-facing error descriptions (raw JSONRPCError) to friendly copy so that
    // "workspace root not found" vs "path escapes workspace" no longer look identical and
    // unfriendly, and offer a recovery path where it makes sense (UX-MAC_FILES-017).
    private static func friendlyError(_ raw: String) -> (title: String, symbol: String, detail: String, offerRoot: Bool) {
        let lower = raw.lowercased()
        if lower.contains("escapes workspace") {
            return ("Outside the workspace", "lock.shield", "That path is outside this workspace. Files stay scoped to the workspace root.", true)
        }
        if lower.contains("workspace root not found") {
            return ("Workspace unavailable", "folder.badge.questionmark", "The workspace folder could not be found. It may have been moved or deleted.", false)
        }
        if lower.contains("not found") {
            return ("Not found", "questionmark.folder", "This path no longer exists in the workspace.", true)
        }
        if lower.contains("permission") || lower.contains("not permitted") {
            return ("Permission denied", "hand.raised", "MacCode can't access this path.", true)
        }
        return ("Files error", "exclamationmark.triangle", raw, true)
    }

    // Clickable breadcrumb so users can jump to any ancestor without typing full paths or
    // clicking up through ".." repeatedly (UX-MAC_FILES-014).
    private var breadcrumb: some View {
        let segments = model.currentDirectory.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("root") { model.loadDirectory("") }
                    .buttonStyle(.plain)
                    .foregroundStyle(segments.isEmpty ? VSCodeTheme.foreground : VSCodeTheme.inactiveForeground)
                    .accessibilityIdentifier("files.breadcrumb.root")
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(VSCodeTheme.inactiveForeground)
                    Button(segment) {
                        model.loadDirectory(segments[0...index].joined(separator: "/"))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == segments.count - 1 ? VSCodeTheme.foreground : VSCodeTheme.inactiveForeground)
                    .accessibilityIdentifier("files.breadcrumb.\(segment)")
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
    }

    private func navigateToParent() {
        let parent = (model.currentDirectory as NSString).deletingLastPathComponent
        model.loadDirectory(parent == "." ? "" : parent)
    }

    private func submitPath() {
        guard let relative = resolveSubmittedFilesPath(raw: pathInput, root: model.root) else {
            pathInput = displayPath
            return
        }
        model.loadDirectory(relative)
        // On a bad path the error surfaces far away in the reader; flag the field red and restore
        // the last valid path so the input doesn't silently keep invalid text (UX-MAC_FILES-013).
        if model.errorText != nil {
            pathInvalid = true
            pathInput = displayPath
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pathInvalid = false }
        } else {
            pathInvalid = false
        }
    }

    private var selectedEntries: [FileEntry] {
        selectedFileIDs.compactMap(model.entryForSelectionID)
    }

    private var deleteTitle: String {
        deleteTargets.count == 1 ? "Move \(deleteTargets[0].name) to Trash?" : "Move \(deleteTargets.count) items to Trash?"
    }

    @ViewBuilder
    private func fileContextMenu(for entry: FileEntry) -> some View {
        let targets = selectedFileIDs.contains(entry.id) && selectedEntries.count > 1 ? selectedEntries : [entry]
        if targets.count == 1 {
            if !entry.isDirectory {
                Button("Open in New Tab") { model.openInNewTab(entry) }
                Divider()
            }
            Button("Reveal in Finder") { revealInFinder(entry) }
            if !entry.isDirectory {
                Button("Open with Default App") { openWithDefaultApp(entry) }
            }
            Divider()
            Button("Rename...") { beginRename(entry) }
            Divider()
            Button("Move to Trash", role: .destructive) { beginDelete(targets) }
        } else {
            Button("Open \(targets.count) Files in New Tabs") {
                targets.filter { !$0.isDirectory }.forEach { model.openInNewTab($0) }
            }
            .accessibilityIdentifier("files.contextMenu.openAllInTabs")
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0.path) })
            }
            .accessibilityIdentifier("files.contextMenu.revealAll")
            Divider()
            Button("Move \(targets.count) Items to Trash", role: .destructive) { beginDelete(targets) }
        }
    }

    private func createNewFile() {
        model.createFile(named: newFileName)
        newFileName = ""
    }

    private func createNewFolder() {
        model.createFolder(named: newFolderName)
        newFolderName = ""
    }

    // Escape hatches to the real file via Finder / default app, for binaries and large media
    // that RemoteCode can't render usefully (UX-MAC_FILES-009).
    private func revealInFinder(_ entry: FileEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    private func openWithDefaultApp(_ entry: FileEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    private func beginRename(_ entry: FileEntry) {
        selectedFileIDs = [entry.id]
        renamingEntry = entry
        renameText = entry.name
        // Pre-select the basename (not the extension) once the alert's text field
        // becomes first responder. The alert is presented asynchronously by SwiftUI,
        // so we defer one run-loop turn to reach the field editor.
        let selectionRange = filesBasenameSelectionRange(for: entry.name)
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let editor = window.fieldEditor(false, for: nil) as? NSTextView else { return }
            editor.selectedRange = selectionRange
        }
    }

    private func commitRename() {
        guard let entry = renamingEntry else { return }
        model.rename(entry, to: renameText)
        selectedFileIDs = []
        renamingEntry = nil
    }

    private func beginDelete(_ entries: [FileEntry]) {
        deleteTargets = entries
        confirmDelete = true
    }

    private func commitDelete() {
        model.delete(deleteTargets)
        selectedFileIDs.subtract(deleteTargets.map(\.id))
        deleteTargets = []
    }

    private var reader: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if !model.openTabs.isEmpty {
                    openTabBar
                    Divider().overlay(DS.Palette.line)
                }
                readerHeader
                Divider().overlay(DS.Palette.line)
                if model.conflictActive {
                    conflictBanner
                    Divider().overlay(DS.Palette.line)
                }
                if model.remoteEditConflict {
                    remoteEditConflictBanner
                    Divider().overlay(DS.Palette.line)
                }
                if let saveErr = model.saveError {
                    saveErrorBanner(saveErr)
                    Divider().overlay(DS.Palette.line)
                }
                if let error = model.errorText {
                    let mapped = Self.friendlyError(error)
                    FilesEmptyState(title: mapped.title, symbol: mapped.symbol, detail: mapped.detail) {
                        if mapped.offerRoot {
                            Button("Go to Workspace Root") { model.loadDirectory("") }
                                .accessibilityIdentifier("files.error.goRoot")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("files.emptyState.error")
                } else if model.selectedEntry == nil {
                    FilesEmptyState(title: "Select a file", symbol: "doc.text.magnifyingglass", detail: "Workspace files stay scoped to this root.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("files.emptyState.select")
                } else {
                    previewBody
                }
            }
	            .dropDestination(for: String.self) { values, location in
	                dropTargeted = false
	                guard let payload = values.compactMap(fileTabDragPayloadCandidate(in:)).first else { return false }
	                return model.handleFileDropPayload(payload, location: location, size: proxy.size)
	            } isTargeted: { targeted in
                dropTargeted = targeted
            }
            // Show where a dragged file tab will land so the user isn't guessing right-vs-bottom
            // split until release (UX-MAC_FILES-018). The destination computes direction by the
            // drop's y-position; the overlay mirrors that split affordance during drag-over.
            .overlay {
                if dropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .stroke(DS.Palette.accent, lineWidth: 2)
                        Text("Drop to split")
                            .font(DS.Font.captionStrong)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(DS.Palette.surfaceRaised, in: Capsule())
                            .foregroundStyle(DS.Palette.accent)
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("files.split.dropIndicator")
                }
            }
            .background(VSCodeTheme.editorBackground)
        }
    }

    // Conflict is rendered as an actionable banner instead of a dead-end sentence in errorText,
    // so the named actions actually exist inline (UX-MAC_FILES-016). "Reload from Disk" is the
    // host-backed resolution (discard re-reads disk); "Keep Editing" hides the banner so the user
    // can continue with their draft. A force-save ("Keep My Changes") needs a host change and is
    // intentionally not offered here, since filesEditSave rejects a save over a changed disk.
    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("File changed outside MacCode")
                    .font(DS.Font.bodyStrong)
                Text("Saving is blocked until you reload. Reloading replaces your draft with the on-disk version.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Keep Editing") { model.conflictActive = false }
                .help("Dismiss this notice and keep your unsaved draft")
                .accessibilityIdentifier("files.conflict.keepEditing")
            Button("Reload from Disk") { model.discard() }
                .help("Replace your draft with the current file on disk")
                .accessibilityIdentifier("files.conflict.reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.surfaceRaised)
    }

    /// Shown when a remote (iOS) edit arrives while the user has unsaved local edits.
    /// The local draft is always preserved. The user can load the remote version
    /// explicitly or dismiss to keep typing.
    private var remoteEditConflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(DS.Palette.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote changes arrived")
                    .font(DS.Font.bodyStrong)
                Text("Your local edits are preserved. Load the remote version to review it, or keep editing.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Keep Editing") { model.dismissRemoteEditConflict() }
                .help("Dismiss this notice and continue with your local draft")
                .accessibilityIdentifier("files.remoteConflict.keepEditing")
            Button("Load Remote") { model.loadRemoteEdit() }
                .help("Replace your local draft with the incoming remote version")
                .accessibilityIdentifier("files.remoteConflict.loadRemote")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.surfaceRaised)
        .accessibilityIdentifier("files.remoteConflict.banner")
    }

    /// Inline banner for save failures (P1: keep editor visible so the user's
    /// draft is not hidden behind an empty-state while they have unsaved work).
    private func saveErrorBanner(_ message: String) -> some View {
        let mapped = Self.friendlyError(message)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("Save failed")
                    .font(DS.Font.bodyStrong)
                Text(mapped.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissSaveError() }
                .help("Dismiss this error")
                .accessibilityIdentifier("files.saveError.dismiss")
            Button("Retry") { model.save() }
                .help("Try saving again")
                .accessibilityIdentifier("files.saveError.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.surfaceRaised)
        .accessibilityIdentifier("files.saveError.banner")
    }

    /// VS Code-style editor tab strip: active tab, dirty dot, per-tab close.
    private var openTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.openTabs) { entry in
                    openTab(entry)
                }
            }
        }
        .frame(height: 35)
        .background(VSCodeTheme.tabsContainer)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VSCodeTheme.border).frame(height: 1)
        }
        .accessibilityIdentifier("files.tabs.strip")
    }

    private func openTab(_ entry: FileEntry) -> some View {
        let isActive = model.selectedEntry?.id == entry.id
        let isDirty = model.isTabDirty(entry)
        let isHovered = hoveredTabID == entry.id
        let showDot = isDirty && !isHovered
        let showClose = !showDot && (isHovered || isActive)
        let closeHovered = hoveredCloseTabID == entry.id
        return HStack(spacing: 6) {
            Image(systemName: entry.icon)
                .font(.system(size: 14))
                .foregroundStyle(VSCodeTheme.color(fileIconColorHex(for: entry.name)))
            Text(entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Button {
                model.closeTab(entry)
            } label: {
                ZStack {
                    if showDot {
                        Circle()
                            .fill(VSCodeTheme.dirty)
                            .frame(width: 8, height: 8)
                    } else if showClose {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                }
                .frame(width: 20, height: 20)
                .background(closeHovered ? Color.white.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside {
                    hoveredCloseTabID = entry.id
                } else if hoveredCloseTabID == entry.id {
                    hoveredCloseTabID = nil
                }
            }
            .help("Close \(entry.name)")
            .accessibilityLabel(isDirty ? "Close \(entry.name), Unsaved changes" : "Close \(entry.name)")
            .accessibilityIdentifier("files.tab.close.\(entry.relativePath)")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 80, minHeight: 35, maxHeight: 35)
        .foregroundStyle(isActive ? Color.white : VSCodeTheme.inactiveForeground)
        .background(isActive ? VSCodeTheme.activeTab : VSCodeTheme.inactiveTab)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(VSCodeTheme.tabActiveBorderTop).frame(height: 1)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(VSCodeTheme.border).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredTabID = entry.id
            } else if hoveredTabID == entry.id {
                hoveredTabID = nil
            }
        }
        .onTapGesture { model.activateTab(entry) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("files.tab.\(entry.relativePath)")
    }

    /// Breadcrumb bar above the editor with the reader controls on the right.
    private var readerHeader: some View {
        HStack(spacing: 8) {
            if !sidebarVisible {
                DSIconButton("sidebar.left", help: "Show file sidebar") {
                    sidebarIntent = .forcedVisible
                    sidebarVisible = true
                }
                .accessibilityLabel("Show file sidebar")
            }
            breadcrumbPath
            Spacer(minLength: 8)
            if model.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Palette.warning)
            }
            Text(model.syncLabel)
                .font(.system(size: 11))
                .foregroundStyle(VSCodeTheme.inactiveForeground)
                .help(model.syncDetail)
                .accessibilityIdentifier("files.sync.label")
            Picker("", selection: $model.readerMode) {
                Text("Source").tag("source")
                Text("Preview").tag("preview")
                Text("Split").tag("split")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 150)
            .onChange(of: model.readerMode) { newValue in model.setReaderMode(newValue) }
            .accessibilityIdentifier("files.readerMode.picker")
            // UX-P3: visible text labels so the Save/Discard affordance is legible
            // without relying on the tooltip or icon recognition alone.
            Button { model.save() } label: {
                HStack(spacing: 4) {
                    DisketteIcon()
                        .frame(width: 12, height: 12)
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .help("Save (Command-S)")
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.isDirty)
            .accessibilityLabel("Save file")
            .accessibilityIdentifier("files.save.button")
            Button { confirmDiscard = true } label: {
                Label("Discard", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
            }
            // UX-P3: keyboard shortcut for discard so keyboard users can trigger
            // the confirm dialog without reaching for the mouse.
            .help("Discard unsaved changes (Command-Delete)")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!model.isDirty)
            .accessibilityLabel("Discard unsaved changes")
            .accessibilityIdentifier("files.discard.button")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(VSCodeTheme.editorBackground)
    }

    /// Path segments of the selected file, shown as the editor breadcrumb.
    private var breadcrumbPath: some View {
        let segments = (model.selectedEntry?.relativePath ?? "").split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if segments.isEmpty {
                    Text("No file selected")
                        .foregroundStyle(VSCodeTheme.inactiveForeground)
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let isLast = index == segments.count - 1
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(VSCodeTheme.inactiveForeground)
                    }
                    if isLast, let entry = model.selectedEntry {
                        Image(systemName: entry.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(VSCodeTheme.color(fileIconColorHex(for: entry.name)))
                    }
                    Text(segment)
                        .foregroundStyle(isLast ? VSCodeTheme.foreground : VSCodeTheme.inactiveForeground)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .frame(height: 22)
        .accessibilityIdentifier("files.editor.breadcrumbs")
    }

    private var sidebarIntent: AdaptiveSidebarIntent {
        get { AdaptiveSidebarIntent(rawValue: sidebarIntentRaw) ?? .auto }
        nonmutating set { sidebarIntentRaw = newValue.rawValue }
    }

    private var readerMinimumWidth: CGFloat {
        model.readerMode == "split" ? 700 : 520
    }

    private func applyAdaptiveSidebar(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width,
            contentMinimumExtent: readerMinimumWidth,
            sidebarExtent: CGFloat(sidebarWidth) + DS.ResizeDivider.thickness,
            currentVisible: sidebarVisible,
            intent: sidebarIntent,
            event: event,
            now: now,
            lastAutomaticChange: lastAutomaticSidebarChange
        )
        guard decision.isVisible != sidebarVisible else { return }
        sidebarVisible = decision.isVisible
        if decision.didChangeAutomatically {
            lastAutomaticSidebarChange = now
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        if let entry = model.selectedEntry {
            switch entry.kind {
            case "markdown":
                sourcePreview(markdown: true)
            case "html":
                sourcePreview(markdown: false)
            case "image":
                LargeMediaGuard(entry: entry, url: model.previewURL) { url in ImagePreview(url: url) }
            case "video":
                LargeMediaGuard(entry: entry, url: model.previewURL) { url in VideoPreview(url: url) }
            case "pdf":
                LargeMediaGuard(entry: entry, url: model.previewURL) { url in WebFileView(url: url) }
            case "code", "text":
                sourcePreview(markdown: false)
            default:
                BinaryMetadataView(entry: entry)
            }
        }
    }

    // Computes the HTML string for the current source text and kind.
    // Called once on appear and again after each debounced change.
    private func computePreviewHTML(markdown: Bool) -> String {
        if markdown {
            return MarkdownSurface.renderHTML(markdown: model.draftText)
        } else if model.selectedEntry?.kind == "html" {
            return model.draftText
        } else {
            return highlightedHTML(text: model.draftText, language: model.selectedEntry?.language)
        }
    }

    // Schedules a debounced recompute of cachedPreviewHTML.
    // If called within previewDebounceInterval of a prior call the timer resets.
    private func schedulePreviewRecompute(markdown: Bool) {
        previewDebounceTimer?.invalidate()
        previewDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.previewDebounceInterval,
            repeats: false
        ) { _ in
            cachedPreviewHTML = computePreviewHTML(markdown: markdown)
            previewDebounceTimer = nil
        }
    }

    @ViewBuilder
    private func sourcePreview(markdown: Bool) -> some View {
        if model.readerMode == "preview" {
            PreviewWebView(html: cachedPreviewHTML, baseURL: model.previewURL?.deletingLastPathComponent())
        } else if model.readerMode == "split" {
            HStack(spacing: 0) {
                editor
                Divider().overlay(DS.Palette.line)
                PreviewWebView(html: cachedPreviewHTML, baseURL: model.previewURL?.deletingLastPathComponent())
            }
        } else {
            editor
        }
    }

    private var editor: some View {
        CodeTextEditor(
            text: $model.draftText,
            language: model.selectedEntry?.language,
            filePath: model.selectedPath ?? model.root,
            absolutePath: model.selectedEntry?.path,
            rootPath: model.root,
            inlineCompletionProvider: model.inlineCompletionProvider,
            onCaretChange: { line, column in
                model.caretLine = line
                model.caretColumn = column
            }
        ) { newValue in
            model.editorChanged(newValue)
        }
    }

    private func treeRow<Disclosure: View>(
        icon: String,
        iconColor: Color,
        name: String,
        depth: Int,
        active: Bool = false,
        focused: Bool = false,
        hovered: Bool = false,
        dirty: Bool = false,
        dirtyPath: String? = nil,
        @ViewBuilder disclosure: () -> Disclosure
    ) -> some View {
        let fill: Color = focused ? VSCodeTheme.listFocusedSelection
            : active ? VSCodeTheme.listActiveSelection
            : hovered ? VSCodeTheme.listHover
            : .clear
        return HStack(spacing: 0) {
            Spacer().frame(width: 8)
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(VSCodeTheme.indentGuide.opacity(0.4))
                    .frame(width: 1, height: 22)
                    .frame(width: 8, height: 22)
            }
            disclosure()
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 22)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(dirty ? VSCodeTheme.modifiedText : VSCodeTheme.foreground)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            if dirty {
                Circle()
                    .fill(VSCodeTheme.dirty)
                    .frame(width: 8, height: 8)
                    .padding(.trailing, 8)
                    .accessibilityLabel("Unsaved changes")
                    .accessibilityIdentifier("files.dirtyDot.\(dirtyPath ?? "")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 22)
        .background(fill)
        .overlay {
            if focused {
                Rectangle().stroke(VSCodeTheme.focusBorder, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    /// Bottom status bar: branch and workspace on the left, editor state on the right.
    private var statusBar: some View {
        let entry = model.selectedEntry
        let isText = entry?.kind == "code" || entry?.kind == "text"
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text((model.root as NSString).lastPathComponent)
            if let entry = entry, !entry.isDirectory, let detail = fileMetaSubtitle(entry) {
                Text(detail)
                    .accessibilityIdentifier("files.header.meta")
            }
            Spacer(minLength: 8)
            if isText {
                Text("Ln \(model.caretLine), Col \(model.caretColumn)")
                    .accessibilityIdentifier("files.status.cursor")
                Text("Spaces: 4")
                Text("UTF-8")
                Text("LF")
                Text(languageDisplayName(entry?.language))
                    .accessibilityIdentifier("files.status.language")
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                    Text("Distill")
                }
                .foregroundStyle(model.inlineCompletionProvider != nil ? VSCodeTheme.statusBarForeground : VSCodeTheme.statusBarForeground.opacity(0.5))
                .accessibilityIdentifier("files.status.distill")
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundStyle(VSCodeTheme.statusBarForeground)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(VSCodeTheme.statusBar)
        .overlay(alignment: .top) {
            Rectangle().fill(VSCodeTheme.statusBarBorder).frame(height: 1)
        }
    }
}

/// Gate large media (image/video/PDF) behind an explicit confirmation so selecting a multi-GB
/// video or huge image does not stall/spike memory by decoding/streaming it immediately. Text
/// reads are already byte-capped; media previews load straight from disk (UX-MAC_FILES-008).
private struct LargeMediaGuard<Content: View>: View {
    static var threshold: Int { LargeMediaGuardThreshold }
    let entry: FileEntry
    let url: URL?
    @ViewBuilder let content: (URL?) -> Content
    @State private var loadAnyway = false

    var body: some View {
        if shouldGateLargeMedia(size: entry.size, loadAnyway: loadAnyway, threshold: Self.threshold) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(DS.Palette.textTertiary)
                Text("Large file")
                    .font(DS.Font.title3)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)) - loading it in MacCode may be slow.")
                    .font(DS.Font.bodyDense)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 8) {
                    Button("Open Externally") {
                        if let url { NSWorkspace.shared.open(url) }
                    }
                    .accessibilityIdentifier("files.largeMedia.openExternal")
                    Button("Load Anyway") { loadAnyway = true }
                        .accessibilityIdentifier("files.largeMedia.loadAnyway")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.bg)
            .onChange(of: entry.id) { _ in loadAnyway = false }
        } else {
            content(url)
                .onChange(of: entry.id) { _ in loadAnyway = false }
        }
    }
}

private struct ImagePreview: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(DS.Palette.bg)
            } else if failed {
                FilesEmptyState(title: "Image unavailable", symbol: "photo", detail: "")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Palette.bg)
            }
        }
        // Decode once off the main thread into a downsampled image instead of re-decoding the
        // full-resolution NSImage on every layout pass (resize, sidebar drag) (PERF-MAC_FILES-005).
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { failed = true; return }
            let decoded = await Self.decodeDownsampled(url: url)
            guard !Task.isCancelled else { return }
            if let decoded { image = decoded } else { failed = true }
        }
    }

    private static func decodeDownsampled(url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            decodeFilesImageThumbnail(url: url)
        }.value
    }
}

private struct DisketteIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let rect = CGRect(x: (proxy.size.width - size) / 2, y: (proxy.size.height - size) / 2, width: size, height: size)
            let line = max(1.6, size * 0.13)
            ZStack {
                DisketteOutline()
                    .stroke(.primary, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                DisketteShutter()
                    .stroke(.primary, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                RoundedRectangle(cornerRadius: size * 0.04)
                    .stroke(.primary, lineWidth: line)
                    .frame(width: size * 0.45, height: size * 0.23)
                    .offset(y: size * 0.25)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .accessibilityLabel("Save")
    }
}

private struct DisketteOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.18, 0.08))
        path.addLine(to: point(0.72, 0.08))
        path.addLine(to: point(0.92, 0.28))
        path.addLine(to: point(0.92, 0.82))
        path.addQuadCurve(to: point(0.82, 0.92), control: point(0.92, 0.92))
        path.addLine(to: point(0.18, 0.92))
        path.addQuadCurve(to: point(0.08, 0.82), control: point(0.08, 0.92))
        path.addLine(to: point(0.08, 0.18))
        path.addQuadCurve(to: point(0.18, 0.08), control: point(0.08, 0.08))
        path.closeSubpath()
        return path
    }
}

private struct DisketteShutter: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.28, 0.08))
        path.addLine(to: point(0.28, 0.40))
        path.addQuadCurve(to: point(0.38, 0.50), control: point(0.28, 0.50))
        path.addLine(to: point(0.62, 0.50))
        path.addQuadCurve(to: point(0.72, 0.40), control: point(0.72, 0.50))
        path.addLine(to: point(0.72, 0.08))
        path.move(to: point(0.50, 0.08))
        path.addLine(to: point(0.50, 0.32))
        return path
    }
}

private struct VideoPreview: View {
    let url: URL?
    @StateObject private var holder = VideoPlayerHolder()

    var body: some View {
        Group {
            if url != nil {
                VideoPlayer(player: holder.player)
                    .background(DS.Palette.bg)
            } else {
                FilesEmptyState(title: "Video unavailable", symbol: "play.rectangle", detail: "")
            }
        }
        // Reuse a single AVPlayer across layout passes and swap its item only when the URL
        // changes, instead of allocating a fresh player on every body eval (PERF-MAC_FILES-011).
        .onChange(of: url) { newValue in holder.load(newValue) }
        .onAppear { holder.load(url) }
        .onDisappear { holder.teardown() }
    }
}

/// Owns the AVPlayer for VideoPreview so it survives SwiftUI body re-evaluations and is
/// paused/cleared when the preview disappears, preventing background decode/buffer drain
/// (PERF-MAC_FILES-011).
@MainActor
private final class VideoPlayerHolder: ObservableObject {
    let player = AVPlayer()
    private var currentURL: URL?

    func load(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        if let url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        } else {
            player.replaceCurrentItem(with: nil)
        }
    }

    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }
}

private struct FilesEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(DS.Palette.textTertiary)
            Text(title)
                .font(DS.Font.title3)
            if !detail.isEmpty {
                Text(detail)
                    .font(DS.Font.bodyDense)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
    }
}

extension FilesEmptyState where Actions == EmptyView {
    init(title: String, symbol: String, detail: String) {
        self.init(title: title, symbol: symbol, detail: detail, actions: { EmptyView() })
    }
}

private struct BinaryMetadataView: View {
    let entry: FileEntry
    private var rows: [BinaryMetadataRow] {
        binaryMetadataRows(relativePath: entry.relativePath, mime: entry.mime, size: entry.size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.kind.capitalized, systemImage: "lock.doc")
                .font(DS.Font.title3)
            Text(entry.editabilityReason)
                .foregroundStyle(DS.Palette.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.label) { row in
                    GridRow { Text(row.label); Text(row.value).font(DS.Font.monoSmall) }
                }
            }
            // Escape hatch to the real file for binaries RemoteCode can't render (UX-MAC_FILES-009).
            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                .accessibilityIdentifier("files.binary.reveal")
                Button("Open with Default App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                }
                .accessibilityIdentifier("files.binary.openExternal")
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.bg)
    }
}

// MARK: - Pure debounce gate (no AppKit, no MainActor; tested in DebouncedPreviewRenderingTests)

/// Decides whether the preview web view should re-render at `now` given the last render
/// timestamp and the minimum interval between renders.
///
/// Returns `true` when enough time has elapsed (interval has passed or no render has
/// happened yet), `false` when called within the debounce window. Pure - no side effects.
struct PreviewDebounceGate {
    /// Minimum seconds between successive preview renders.
    let interval: TimeInterval

    /// Returns `true` when a new render should fire.
    /// - Parameters:
    ///   - lastRenderAt: `nil` if the preview has never rendered.
    ///   - now: the current timestamp (seconds; same epoch as `lastRenderAt`).
    func shouldRender(lastRenderAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last = lastRenderAt else { return true }
        return now - last >= interval
    }
}

// MARK: - Pure scroll-restore token (no AppKit, no MainActor; tested in DebouncedPreviewRenderingTests)

/// Carries a captured scroll position so the web view can restore it after an HTML reload.
/// Round-trips through a plain `Double` so it is easy to pass across the JS boundary.
struct PreviewScrollToken: Equatable {
    /// Captured `window.scrollY` value in CSS pixels.
    let scrollY: Double

    /// A sentinel that means "no scroll position to restore" (e.g. first load).
    static let none = PreviewScrollToken(scrollY: 0)

    /// JavaScript fragment that writes back `scrollY` when injected after page load.
    var restoreScript: String {
        "window.scrollTo(0, \(scrollY));"
    }
}

// Light placeholder while the web view first paints, so large markdown/HTML previews don't show
// a blank pane that then pops in (UX-MAC_FILES-015).
private struct PreviewWebView: View {
    let html: String
    let baseURL: URL?
    @State private var firstPaintDone = false

    var body: some View {
        ZStack {
            WebHTMLView(html: html, baseURL: baseURL) { firstPaintDone = true }
            if !firstPaintDone {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Palette.bg)
                    .accessibilityIdentifier("files.preview.loading")
            }
        }
    }
}

private struct WebHTMLView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    var onFirstPaint: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    // Only reload when the HTML actually changes, and throttle reloads with a ~200ms debounce
    // so split-mode typing does not cause a full WKWebView reflow per keystroke.
    // Scroll position is captured before each reload and restored via JS after the page settles
    // so the user's viewport is preserved across renders (PERF-MAC_FILES-006/P2).
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.lastRenderedHTML != html else { return }
        coordinator.pendingHTML = html
        coordinator.pendingBaseURL = baseURL
        coordinator.scheduleDebounced(in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFirstPaint: onFirstPaint) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // The HTML that was most recently sent to WKWebView.loadHTMLString.
        var lastRenderedHTML: String?
        // The HTML waiting to be rendered once the debounce window closes.
        var pendingHTML: String?
        var pendingBaseURL: URL?
        private let onFirstPaint: (() -> Void)?
        private var firstPaintReported = false
        // Scroll token to restore after the next load completes.
        private var pendingScrollToken = PreviewScrollToken.none
        private var debounceTimer: Timer?
        private static let gate = PreviewDebounceGate(interval: 0.2)
        private var lastRenderAt: TimeInterval?

        init(onFirstPaint: (() -> Void)?) {
            self.onFirstPaint = onFirstPaint
        }

        /// Schedule (or reschedule) a debounced render. Captures the current scroll position
        /// before each render so it can be restored via JS once the page settles.
        func scheduleDebounced(in webView: WKWebView) {
            let now = Date().timeIntervalSinceReferenceDate
            if Self.gate.shouldRender(lastRenderAt: lastRenderAt, now: now) {
                // Enough time has passed - render immediately.
                commit(in: webView, now: now)
            } else {
                // Within the debounce window - defer to the end of the interval.
                debounceTimer?.invalidate()
                let remaining = Self.gate.interval - (now - (lastRenderAt ?? now))
                debounceTimer = Timer.scheduledTimer(withTimeInterval: max(remaining, 0.01), repeats: false) { [weak self, weak webView] _ in
                    guard let self, let webView else { return }
                    self.commit(in: webView, now: Date().timeIntervalSinceReferenceDate)
                }
            }
        }

        private func commit(in webView: WKWebView, now: TimeInterval) {
            guard let html = pendingHTML else { return }
            // Capture current scroll position before the reload.
            webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                let scrollY = (result as? Double) ?? 0
                self?.pendingScrollToken = PreviewScrollToken(scrollY: scrollY)
            }
            lastRenderedHTML = html
            lastRenderAt = now
            pendingHTML = nil
            webView.loadHTMLString(html, baseURL: pendingBaseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Restore scroll position after every reload, not just the first.
            if pendingScrollToken.scrollY > 0 {
                webView.evaluateJavaScript(pendingScrollToken.restoreScript, completionHandler: nil)
            }
            pendingScrollToken = .none
            guard !firstPaintReported else { return }
            firstPaintReported = true
            onFirstPaint?()
        }
    }
}

private struct WebFileView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    // Skip the reload when the URL is unchanged so unrelated state updates don't reload the PDF
    // (PERF-MAC_FILES-006).
    func updateNSView(_ view: WKWebView, context: Context) {
        guard let url, context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
    }
}

private struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let language: String?
    let filePath: String
    let absolutePath: String?
    let rootPath: String
    let inlineCompletionProvider: (any InlineCompletionProviding)?
    var onCaretChange: (Int, Int) -> Void = { _, _ in }
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        let textView = CodeEditorTextView()
        textView.configureForEditing()
        textView.delegate = context.coordinator
        let palette = EditorColorPalette.resolve(isDark: NSApp.effectiveAppearance.isDark)
        textView.applyEditorStyle(palette)
        context.coordinator.currentPalette = palette
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        textView.language = language
        textView.completionItemsForPrefix = { [weak textView] _, caret in
            guard let textView else { return [] }
            return FileCompletionEngine.completions(in: textView.string, caret: caret, language: language)
        }
        context.coordinator.textView = textView
        context.coordinator.language = language
        context.coordinator.filePath = filePath
        context.coordinator.inlineProvider = inlineCompletionProvider
        let coordinator = context.coordinator
        textView.onCompletionRequest = { [weak coordinator, weak textView] explicit in
            guard let coordinator, let textView else { return }
            coordinator.requestCompletion(in: textView, explicit: explicit)
        }
        textView.onHoverRequest = { [weak coordinator, weak textView] index in
            guard let coordinator, let textView else { return }
            coordinator.requestHover(in: textView, at: index)
        }
        textView.suggest.onDismiss = { [weak coordinator] in coordinator?.cancelCompletion() }
        context.coordinator.rootPath = rootPath
        context.coordinator.absolutePath = absolutePath
        context.coordinator.switchLanguageServer(to: absolutePath)
        context.coordinator.applyHighlight(to: textView)
        scroll.documentView = textView
        let ruler = CodeLineNumberRulerView(textView: textView)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = ruler
        context.coordinator.lineNumberRuler = ruler
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scroll.documentView as? NSTextView else { return }
        context.coordinator.language = language
        context.coordinator.filePath = filePath
        context.coordinator.inlineProvider = inlineCompletionProvider
        (textView as? CodeEditorTextView)?.language = language
        if absolutePath != context.coordinator.absolutePath || rootPath != context.coordinator.rootPath {
            context.coordinator.absolutePath = absolutePath
            context.coordinator.rootPath = rootPath
            context.coordinator.switchLanguageServer(to: absolutePath)
        }
        // Re-apply palette when the system appearance changes (light/dark).
        let newPalette = EditorColorPalette.resolve(isDark: NSApp.effectiveAppearance.isDark)
        if newPalette != context.coordinator.currentPalette {
            context.coordinator.currentPalette = newPalette
            (textView as? CodeEditorTextView)?.applyEditorStyle(newPalette)
            context.coordinator.lineNumberRuler?.currentPalette = newPalette
            context.coordinator.applyHighlight(to: textView)
            return
        }
        if textView.string != text {
            (textView as? CodeEditorTextView)?.clearGhost()
            if let editor = textView as? CodeEditorTextView {
                if let oldText = editor.replaceTextPreservingSelection(text) {
                    context.coordinator.applyHighlightIncremental(oldText: oldText, to: textView)
                }
            } else {
                textView.string = text
                context.coordinator.applyHighlight(to: textView)
            }
            context.coordinator.lineNumberRuler?.invalidateLineStartCache()
            context.coordinator.lineNumberRuler?.needsDisplay = true
            context.coordinator.documentReplacedExternally()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onCaretChange: onCaretChange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (String) -> Void
        let onCaretChange: (Int, Int) -> Void
        private var lastCaret: (line: Int, column: Int)?
        weak var textView: CodeEditorTextView?
        weak var lineNumberRuler: CodeLineNumberRulerView?
        var language: String?
        var filePath = ""
        var inlineProvider: (any InlineCompletionProviding)?
        private var applyingHighlight = false
        private var inlineTask: Task<Void, Never>?
        private var inlineDebounceTimer: Timer?
        private var inlineGeneration = 0
        var absolutePath: String?
        var rootPath = ""
        private var lspClient: LanguageServerClient?
        private var lspPath: String?
        private var lspGeneration = 0
        private var lspDirty = false
        private var lspLease: (command: [String], root: String)?
        private var lspSubscription: (client: LanguageServerClient, id: UUID)?
        private var lspOpenTask: Task<Void, Never>?
        private var lspSendTail: Task<Void, Never>?
        private var lspChangeTimer: Timer?
        private var completionGeneration = 0
        private var hoverGeneration = 0
        private var completionTask: Task<Void, Never>?
        /// Entries last shown and the document text they were computed for.
        private var completionEntries: [SuggestEntry] = []
        private var completionDocumentText: String?
        private static var loggedLanguageFailures = Set<String>()
        /// Last applied palette; compared in `updateNSView` to skip redundant attribute churn.
        var currentPalette: EditorColorPalette = EditorColorPalette.resolve(isDark: true)

        init(onChange: @escaping (String) -> Void, onCaretChange: @escaping (Int, Int) -> Void) {
            self.onChange = onChange
            self.onCaretChange = onCaretChange
        }

        deinit {
            inlineTask?.cancel()
            inlineDebounceTimer?.invalidate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeEditorTextView else { return }
            onChange(textView.string)
            textView.clearGhost()
            highlightEditedRange(in: textView)
            lineNumberRuler?.invalidateLineStartCache()
            lineNumberRuler?.needsDisplay = true
            scheduleInlineCompletion(in: textView)
            scheduleLanguageServerChange()
            updateSuggestions(in: textView)
        }

        // MARK: IntelliSense

        /// Auto trigger: an identifier character, `.` or `::` before the caret requests
        /// completions. Any other typed character hides the list.
        private func updateSuggestions(in textView: CodeEditorTextView) {
            guard !textView.isAcceptingSuggestion else { return }
            let caret = textView.selectedRange().location
            guard caret > 0 else {
                textView.suggest.hide()
                return
            }
            let ns = textView.string as NSString
            let previous = ns.character(at: caret - 1)
            if FileCompletionEngine.isIdentifierCharacter(previous) {
                if textView.suggest.isVisible {
                    if textView.string != completionDocumentText {
                        // LSP ranges were computed for the older text; fall back to the current word.
                        completionEntries = completionEntries.map { entry in
                            var entry = entry
                            entry.replaceRange = nil
                            return entry
                        }
                        showSuggestions(completionEntries, prefix: currentPrefix(in: textView), in: textView)
                    } else {
                        textView.suggest.update(prefix: currentPrefix(in: textView))
                    }
                }
                requestCompletion(in: textView, explicit: false)
            } else if previous == 0x2E || (previous == 0x3A && caret > 1 && ns.character(at: caret - 2) == 0x3A) {
                textView.suggest.hide()
                requestCompletion(in: textView, explicit: false)
            } else {
                textView.suggest.hide()
            }
        }

        private func currentPrefix(in textView: CodeEditorTextView) -> String {
            let text = textView.string
            guard let range = FileCompletionEngine.replacementRange(in: text, caret: textView.selectedRange().location) else {
                return ""
            }
            return (text as NSString).substring(with: range)
        }

        /// Word entries show at once; LSP entries merge in when they return, if still current.
        func requestCompletion(in textView: CodeEditorTextView, explicit: Bool) {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return }
            let text = textView.string
            let caret = selection.location
            let prefix = currentPrefix(in: textView)
            let words = wordEntries(FileCompletionEngine.completions(in: text, caret: caret, language: language))
            completionGeneration += 1
            let generation = completionGeneration
            completionTask?.cancel()
            if explicit || !textView.suggest.isVisible {
                showSuggestions(words, prefix: prefix, in: textView)
            }
            guard let client = lspClient, let path = lspPath else { return }
            let position = LSPText.position(forUTF16Offset: caret, in: text)
            let pending = flushLanguageServerChange()
            completionTask = Task { @MainActor [weak self, weak textView] in
                await pending?.value
                let items = (try? await client.completion(path: path, position: position)) ?? []
                guard !Task.isCancelled, let self, let textView, generation == self.completionGeneration,
                      textView.string == text,
                      textView.selectedRange() == NSRange(location: caret, length: 0),
                      textView.window?.firstResponder === textView else { return }
                let merged = items.map { self.languageServerEntry($0, in: text) } + words
                self.showSuggestions(merged, prefix: prefix, in: textView)
            }
        }

        private func showSuggestions(_ entries: [SuggestEntry], prefix: String, in textView: CodeEditorTextView) {
            guard !entries.isEmpty else {
                textView.suggest.hide()
                return
            }
            completionEntries = entries
            completionDocumentText = textView.string
            textView.suggest.show(entries: entries, prefix: prefix, anchor: textView.caretRect(), in: textView)
        }

        /// Invalidates in-flight LSP results. Bound to Escape in the suggest widget.
        func cancelCompletion() {
            completionGeneration += 1
            completionTask?.cancel()
            completionTask = nil
        }

        /// Text changed without typing (remote/disk update). Hides suggestions and syncs the server.
        func documentReplacedExternally() {
            cancelCompletion()
            textView?.suggest.hide()
            scheduleLanguageServerChange()
        }

        private func wordEntries(_ items: [FileCompletionItem]) -> [SuggestEntry] {
            items.map { item in
                SuggestEntry(
                    label: item.label,
                    insertText: item.insertText,
                    kind: SuggestKind(item.kind),
                    detail: item.detail,
                    documentation: nil,
                    sortText: nil,
                    filterText: nil,
                    replaceRange: nil,
                    source: .word
                )
            }
        }

        private func languageServerEntry(_ item: LSPCompletionItem, in text: String) -> SuggestEntry {
            SuggestEntry(
                label: item.label,
                insertText: item.insertText,
                kind: SuggestKind(lspKind: item.kind),
                detail: item.detail,
                documentation: item.documentation,
                sortText: item.sortText,
                filterText: item.filterText,
                replaceRange: item.replaceRange.map { editorNSRange($0, in: text) },
                source: .languageServer
            )
        }

        // MARK: Language server

        /// Opens `path` on the shared server for `rootPath`. Closes the previous file first.
        /// No server for the file type means word completion only.
        func switchLanguageServer(to path: String?) {
            lspGeneration += 1
            let generation = lspGeneration
            lspChangeTimer?.invalidate()
            lspChangeTimer = nil
            lspOpenTask?.cancel()
            lspOpenTask = nil
            completionTask?.cancel()
            if let oldPath = lspPath, let client = lspClient {
                let previous = lspSendTail
                Task { await previous?.value; await client.didClose(path: oldPath) }
            }
            lspClient = nil
            lspPath = nil
            lspDirty = false
            lspSendTail = nil
            let previousSubscription = lspSubscription
            let previousLease = lspLease
            lspSubscription = nil
            lspLease = nil
            // Acquire the next lease before releasing the old one so switching files on the
            // same server never drops the pool's lease count to zero and restarts it.
            let releasePrevious: @Sendable () async -> Void = {
                if let previousSubscription { await previousSubscription.client.removeDiagnosticsHandler(previousSubscription.id) }
                if let previousLease { await LanguageServerPool.shared.release(command: previousLease.command, rootPath: previousLease.root) }
            }
            guard let path, !rootPath.isEmpty,
                  let command = LanguageServerRegistry.command(forPath: path, language: language) else {
                Task { await releasePrevious() }
                return
            }
            let root = rootPath
            let languageID = LanguageServerRegistry.languageID(forPath: path)
            lspOpenTask = Task { @MainActor [weak self] in
                let client: LanguageServerClient
                do {
                    client = try await LanguageServerPool.shared.client(command: command, rootPath: root)
                    await releasePrevious()
                } catch {
                    await releasePrevious()
                    self?.logLanguageServerFailure(command)
                    return
                }
                guard let self, generation == self.lspGeneration else {
                    await LanguageServerPool.shared.release(command: command, rootPath: root)
                    return
                }
                let id = await client.addDiagnosticsHandler { [weak self] diagPath, diagnostics in
                    Task { @MainActor in self?.applyLanguageDiagnostics(path: diagPath, diagnostics) }
                }
                guard generation == self.lspGeneration, let textView = self.textView else {
                    await client.removeDiagnosticsHandler(id)
                    await LanguageServerPool.shared.release(command: command, rootPath: root)
                    return
                }
                self.lspLease = (command, root)
                self.lspSubscription = (client, id)
                self.lspSendTail = Task { await client.didOpen(path: path, languageID: languageID, version: 1, text: textView.string) }
                self.lspClient = client
                self.lspPath = path
                self.lspDirty = false
                self.lspOpenTask = nil
            }
        }

        func tearDown() {
            lspGeneration += 1
            lspChangeTimer?.invalidate()
            lspChangeTimer = nil
            lspOpenTask?.cancel()
            lspOpenTask = nil
            completionTask?.cancel()
            completionTask = nil
            if let path = lspPath, let client = lspClient {
                let previous = lspSendTail
                Task { await previous?.value; await client.didClose(path: path) }
            }
            lspClient = nil
            lspPath = nil
            lspSendTail = nil
            releaseLanguageServer()
            textView?.suggest.hide()
            textView?.hideHover()
        }

        /// Removes this coordinator's diagnostics subscriber and drops its pool lease.
        /// The returned task finishes before a following acquire, so the server is not stopped and restarted.
        @discardableResult
        private func releaseLanguageServer() -> Task<Void, Never>? {
            let subscription = lspSubscription
            let lease = lspLease
            lspSubscription = nil
            lspLease = nil
            guard subscription != nil || lease != nil else { return nil }
            return Task {
                if let subscription { await subscription.client.removeDiagnosticsHandler(subscription.id) }
                if let lease { await LanguageServerPool.shared.release(command: lease.command, rootPath: lease.root) }
            }
        }

        private func logLanguageServerFailure(_ command: [String]) {
            let exe = command.first ?? ""
            guard Self.loggedLanguageFailures.insert(exe).inserted else { return }
            NSLog("[files.lsp] launch failed for %@; using word completion only", exe)
        }

        private func applyLanguageDiagnostics(path: String, _ diagnostics: [LSPDiagnostic]) {
            guard path == absolutePath, let textView else { return }
            textView.applyDiagnostics(diagnostics)
        }

        private func scheduleLanguageServerChange() {
            guard lspPath != nil || lspOpenTask != nil else { return }
            lspDirty = true
            lspChangeTimer?.invalidate()
            lspChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.flushLanguageServerChange() }
            }
        }

        /// Queues a full-text didChange when dirty. Returns the send queue tail so requests can wait for it.
        @discardableResult
        private func flushLanguageServerChange() -> Task<Void, Never>? {
            lspChangeTimer?.invalidate()
            lspChangeTimer = nil
            guard lspDirty, let client = lspClient, let path = lspPath, let textView = self.textView else {
                return lspSendTail
            }
            lspDirty = false
            let previous = lspSendTail
            let text = textView.string
            lspSendTail = Task { await previous?.value; await client.didChange(path: path, text: text) }
            return lspSendTail
        }

        func requestHover(in textView: CodeEditorTextView, at index: Int) {
            guard let client = lspClient, let path = lspPath else { return }
            hoverGeneration += 1
            let generation = hoverGeneration
            let text = textView.string
            let position = LSPText.position(forUTF16Offset: index, in: text)
            let pending = flushLanguageServerChange()
            Task { @MainActor [weak self, weak textView] in
                await pending?.value
                let hover = try? await client.hover(path: path, position: position)
                guard let self, let textView, let hover, generation == self.hoverGeneration,
                      textView.hoverIndex == index, textView.string == text else { return }
                textView.showHover(hover, at: index)
            }
        }

        // MARK: Distill inline completion

        /// One request per typing pause. The result is stored as ghost text
        /// only; the document is never mutated until the user presses Tab.
        private func scheduleInlineCompletion(in textView: CodeEditorTextView) {
            inlineDebounceTimer?.invalidate()
            inlineTask?.cancel()
            guard let provider = inlineProvider, !textView.string.isEmpty else { return }
            inlineGeneration += 1
            let generation = inlineGeneration
            let path = filePath
            let language = language
            let text = textView.string
            let caret = textView.selectedRange().location
            guard textView.selectedRange().length == 0 else { return }
            inlineDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                let request = InlineCompletionRequest(path: path, language: language, text: text, caret: caret)
                self.inlineTask = Task { [weak self, weak textView] in
                    let completion = try? await provider.complete(request)
                    guard !Task.isCancelled, let self, let textView, let completion else { return }
                    await MainActor.run {
                        guard generation == self.inlineGeneration,
                              textView.string == text,
                              textView.selectedRange().location == caret,
                              textView.selectedRange().length == 0 else { return }
                        textView.showGhost(completion, at: caret)
                    }
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? CodeEditorTextView else { return }
            if textView.selectedRange().length > 0 { textView.clearGhost() }
            let caret = caretLineColumn(text: textView.string, utf16Offset: textView.selectedRange().location)
            guard lastCaret?.line != caret.line || lastCaret?.column != caret.column else { return }
            lastCaret = caret
            onCaretChange(caret.line, caret.column)
        }

        /// Re-highlight only the paragraph(s) touched by the last edit instead of the whole
        /// document, keeping per-keystroke cost bounded for large files (PERF-MAC_FILES-001).
        private func highlightEditedRange(in textView: NSTextView) {
            guard !applyingHighlight, let storage = textView.textStorage else { return }
            applyingHighlight = true
            defer { applyingHighlight = false }
            let nsText = storage.string as NSString
            let edited = storage.editedRange.location == NSNotFound
                ? NSRange(location: 0, length: nsText.length)
                : storage.editedRange
            let clampedLocation = min(edited.location, nsText.length)
            let safeEdited = NSRange(location: clampedLocation,
                                     length: min(edited.length, nsText.length - clampedLocation))
            let paragraphRange = nsText.paragraphRange(for: safeEdited)
            let baseAttrs = codeBaseAttributes(for: currentPalette)
            storage.beginEditing()
            storage.setAttributes(baseAttrs, range: paragraphRange)
            nsText.enumerateSubstrings(in: paragraphRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                let lineText = nsText.substring(with: range)
                applyHighlightSpans(highlightCodeLine(lineText), lineRange: range, to: storage)
            }
            storage.endEditing()
            (textView as? CodeEditorTextView)?.reapplyDiagnostics()
        }

        func applyHighlight(to textView: NSTextView) {
            guard !applyingHighlight else { return }
            applyingHighlight = true
            let selectedRanges = textView.selectedRanges
            let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            let text = textView.string
            let attributed = highlightedCodeAttributedString(text, palette: currentPalette)
            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selectedRanges
            if let scrollOrigin {
                textView.enclosingScrollView?.contentView.scroll(to: scrollOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
            }
            (textView as? CodeEditorTextView)?.reapplyDiagnostics()
            lineNumberRuler?.invalidateLineStartCache()
            lineNumberRuler?.needsDisplay = true
            applyingHighlight = false
        }

        /// Re-highlight only the lines that changed between `oldText` and the current textView
        /// content (PERF-MAC_FILES-014). Never moves the selection or scroll offset.
        func applyHighlightIncremental(oldText: String, to textView: NSTextView) {
            guard !applyingHighlight else { return }
            let ranges = changedLineRanges(oldText: oldText, newText: textView.string)
            guard !ranges.isEmpty else { return }
            let nsNew = textView.string as NSString
            let fullRange = NSRange(location: 0, length: nsNew.length)
            if NSEqualRanges(ranges[0], fullRange) {
                applyHighlight(to: textView)
                return
            }
            guard let storage = textView.textStorage else { return }
            applyingHighlight = true
            defer { applyingHighlight = false }
            let baseAttrs = codeBaseAttributes(for: currentPalette)
            storage.beginEditing()
            for range in ranges {
                storage.setAttributes(baseAttrs, range: range)
                nsNew.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                    let lineText = nsNew.substring(with: lineRange)
                    applyHighlightSpans(highlightCodeLine(lineText), lineRange: lineRange, to: storage)
                }
            }
            storage.endEditing()
            lineNumberRuler?.invalidateLineStartCache()
            lineNumberRuler?.needsDisplay = true
        }
    }
}

// MARK: - Editor text view (completion, diagnostics, hover, ghost text)

/// NSTextView subclass that owns IntelliSense, diagnostics, hover and Distill ghost text.
///
/// Completions use `SuggestWidgetController`. Acceptance is one undoable `insertText` edit.
/// AI completions stay non-destructive: they are painted after the caret and inserted only
/// on Tab or Cmd+Right (next word).
final class CodeEditorTextView: NSTextView {
    var language: String?
    var completionItemsForPrefix: ((String, Int) -> [FileCompletionItem])?
    /// `true` for explicit Ctrl+Space, `false` for automatic triggers.
    var onCompletionRequest: ((Bool) -> Void)?
    /// Character index under a rested mouse.
    var onHoverRequest: ((Int) -> Void)?
    /// True while a suggestion is inserted so the insert does not reopen the list.
    var isAcceptingSuggestion = false
    /// Painted diagnostics with their document ranges.
    var diagnostics: [(NSRange, LSPDiagnostic)] = []
    /// Index the pending or shown hover is for; nil when none.
    var hoverIndex: Int?

    lazy var suggest: SuggestWidgetController = {
        let controller = SuggestWidgetController()
        controller.onAccept = { [weak self] entry in self?.acceptSuggestion(entry) }
        return controller
    }()

    private var ghostText: String?
    private var ghostCaret = 0
    private var lastDiagnostics: [LSPDiagnostic] = []
    private var hoverTimer: Timer?
    private var hoverRestPoint: NSPoint?
    private var shownHoverPoint: NSPoint?
    private var hoverTrackingArea: NSTrackingArea?
    private lazy var hoverPanel = EditorHoverPanel()
    private static let ghostColor = NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 0.45)

    private var monoFont: NSFont { font ?? EditorMetrics.font }

    /// TextKit 2 stack so `textLayoutManager` stays non-nil. Any `layoutManager` access would
    /// silently downgrade the view to TextKit 1, so this type never touches it.
    convenience init() {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.textContainer = container
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Dark Modern look: Menlo 12 on an 18pt line, small left padding next to the gutter.
    func applyEditorStyle(_ palette: EditorColorPalette) {
        font = EditorMetrics.font
        defaultParagraphStyle = EditorMetrics.paragraphStyle
        typingAttributes = [
            .font: EditorMetrics.font,
            .foregroundColor: palette.text,
            .paragraphStyle: EditorMetrics.paragraphStyle,
        ]
        backgroundColor = palette.background
        textColor = palette.text
        insertionPointColor = palette.insertionPoint
        selectedTextAttributes = [.backgroundColor: palette.selection]
        textContainerInset = NSSize(width: 0, height: 0)
        textContainer?.lineFragmentPadding = EditorMetrics.leftPadding
        needsDisplay = true
    }

    /// Code-editor behaviour shared by every mount: plain text, no smart
    /// substitutions, undo, and the native incremental find bar.
    func configureForEditing() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    /// Replaces content from a remote/disk update without losing the caret or
    /// selection. Returns the previous text so callers can re-highlight only
    /// the changed lines; nil when the text was already equal.
    @discardableResult
    func replaceTextPreservingSelection(_ newText: String) -> String? {
        guard string != newText else { return nil }
        let old = string
        let selection = selectedRanges
        string = newText
        selectedRanges = selection
        return old
    }

    func showGhost(_ text: String, at caret: Int) {
        var trimmed = text
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return }
        ghostText = trimmed
        ghostCaret = caret
        needsDisplay = true
    }

    func clearGhost() {
        guard ghostText != nil else { return }
        ghostText = nil
        needsDisplay = true
    }

    var hasGhost: Bool { ghostText != nil }

    func acceptGhost() {
        guard let ghost = ghostText else { return }
        let caret = min(ghostCaret, (string as NSString).length)
        ghostText = nil
        insertWithoutSuggest(ghost, range: NSRange(location: caret, length: 0))
        needsDisplay = true
    }

    /// Accepts the next word or line break of the ghost; the remainder stays as ghost.
    private func acceptGhostWord() {
        guard let ghost = ghostText else { return }
        let chunk = GhostTextLayout.nextWordChunk(ghost)
        guard !chunk.isEmpty else { return }
        let caret = min(ghostCaret, (string as NSString).length)
        ghostText = nil
        insertWithoutSuggest(chunk, range: NSRange(location: caret, length: 0))
        let remainder = String(ghost.dropFirst(chunk.count))
        ghostCaret = caret + (chunk as NSString).length
        ghostText = remainder.isEmpty ? nil : remainder
        needsDisplay = true
    }

    func acceptSuggestion(_ entry: SuggestEntry) {
        let caret = selectedRange().location
        var range = FileCompletionEngine.replacementRange(in: string, caret: caret)
            ?? NSRange(location: caret, length: 0)
        if let replace = entry.replaceRange, replace.location <= caret, caret <= NSMaxRange(replace),
           NSMaxRange(replace) <= (string as NSString).length {
            range = replace
        }
        clearGhost()
        insertWithoutSuggest(entry.insertText, range: range)
    }

    private func insertWithoutSuggest(_ text: String, range: NSRange) {
        isAcceptingSuggestion = true
        defer { isAcceptingSuggestion = false }
        // `insertText(_:replacementRange:)` is the same undoable path as typing.
        insertText(text, replacementRange: range)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        let items = completionItemsForPrefix?(string, NSMaxRange(charRange)) ?? []
        guard !items.isEmpty else { return nil }
        index?.pointee = 0
        return items.map(\.insertText)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        insertText(word, replacementRange: charRange)
    }

    /// Caret rect in text-view coordinates.
    func caretRect() -> NSRect {
        caretRect(at: selectedRange().location)
    }

    private func caretRect(at index: Int) -> NSRect {
        textKit2InsertionRect(at: index)
    }

    override func keyDown(with event: NSEvent) {
        if suggest.isVisible, suggest.handleKeyDown(event) { return }
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 49, event.modifierFlags.contains(.control) { // Ctrl+Space
            if suggest.isVisible {
                suggest.toggleDetails()
            } else {
                onCompletionRequest?(true)
            }
            return
        }
        if event.keyCode == 124, command, hasGhost { // Cmd+Right
            acceptGhostWord()
            return
        }
        if event.keyCode == 123 || event.keyCode == 124 {
            suggest.hide()
        }
        hideHover()
        if event.keyCode == 48, hasGhost { // Tab
            acceptGhost()
            return
        }
        if event.keyCode == 53, hasGhost { // Escape
            clearGhost()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        suggest.hide()
        hideHover()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        hideHover()
        super.scrollWheel(with: event)
    }

    override func resignFirstResponder() -> Bool {
        suggest.hide()
        hideHover()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            suggest.hide()
            hideHover()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let shown = shownHoverPoint, hypot(point.x - shown.x, point.y - shown.y) > 4 {
            hideHover()
        }
        hoverRestPoint = point
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hoverRestDidElapse() }
        }
    }

    private func hoverRestDidElapse() {
        hoverTimer = nil
        guard let point = hoverRestPoint, window != nil, !string.isEmpty else { return }
        let index = min(characterIndexForInsertion(at: point), (string as NSString).length - 1)
        hoverIndex = index
        shownHoverPoint = point
        if let hit = diagnostics.first(where: { NSLocationInRange(index, $0.0) }) {
            showHover(hit.1.message, at: index)
            return
        }
        onHoverRequest?(index)
    }

    func showHover(_ text: String, at index: Int) {
        guard window != nil else { return }
        hoverPanel.show(text, above: caretRect(at: index), in: self)
    }

    func hideHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverRestPoint = nil
        shownHoverPoint = nil
        hoverIndex = nil
        hoverPanel.hide()
    }

    /// Replaces the painted diagnostics with `items`.
    func applyDiagnostics(_ items: [LSPDiagnostic]) {
        lastDiagnostics = items
        reapplyDiagnostics()
    }

    /// Recomputes diagnostic ranges against the current text and repaints. Squiggles are drawn in
    /// `draw(_:)` from TextKit 2 segment frames, so storage edits cannot drop them.
    func reapplyDiagnostics() {
        guard !lastDiagnostics.isEmpty || !diagnostics.isEmpty else { return }
        let text = string
        let length = (text as NSString).length
        diagnostics = []
        let lineStarts = buildLineStartOffsets(text: text)
        for item in lastDiagnostics {
            guard Self.underlineColor(forSeverity: item.severity) != nil else { continue }
            var range = diagnosticNSRange(item.range, lineStarts: lineStarts, length: length)
            if range.length == 0 { range.length = min(1, length - range.location) }
            guard range.length > 0 else { continue }
            diagnostics.append((range, item))
        }
        needsDisplay = true
    }

    /// Dotted-underline rectangles (text-view coordinates) for each painted diagnostic.
    func diagnosticUnderlineRects() -> [(rect: NSRect, color: NSColor)] {
        var result: [(NSRect, NSColor)] = []
        for (range, item) in diagnostics {
            guard let color = Self.underlineColor(forSeverity: item.severity) else { continue }
            for rect in textKit2SegmentRects(for: range) {
                result.append((NSRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 2), color))
            }
        }
        return result
    }

    private func drawDiagnosticUnderlines(in dirtyRect: NSRect) {
        for (rect, color) in diagnosticUnderlineRects() where rect.intersects(dirtyRect) {
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.setLineDash([2, 2], count: 2, phase: 0)
            path.move(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.stroke()
        }
    }

    private static func underlineColor(forSeverity severity: Int) -> NSColor? {
        switch severity {
        case 1: return NSColor(srgbRed: 0xF1 / 255.0, green: 0x4C / 255.0, blue: 0x4C / 255.0, alpha: 1)
        case 2: return NSColor(srgbRed: 0xCC / 255.0, green: 0xA7 / 255.0, blue: 0x00 / 255.0, alpha: 1)
        case 3: return NSColor(srgbRed: 0x37 / 255.0, green: 0x94 / 255.0, blue: 0xFF / 255.0, alpha: 1)
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawDiagnosticUnderlines(in: dirtyRect)
        guard let ghostText, let origin = caretOrigin(at: ghostCaret) else { return }
        let parts = GhostTextLayout.split(ghostText)
        let attrs: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: Self.ghostColor]
        if !parts.inline.isEmpty {
            (parts.inline as NSString).draw(at: origin, withAttributes: attrs)
        }
        guard !parts.lines.isEmpty else { return }
        let lineHeight = EditorMetrics.lineHeight
        let x = textContainerOrigin.x
        let width = max(0, visibleRect.maxX - x)
        var y = origin.y + lineHeight
        for line in parts.lines {
            backgroundColor.setFill()
            NSRect(x: x, y: y, width: width, height: lineHeight).fill()
            (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            y += lineHeight
        }
    }

    private func caretOrigin(at index: Int) -> NSPoint? {
        let rect = textKit2InsertionRect(at: index)
        return NSPoint(x: rect.minX, y: rect.minY)
    }
}

/// LSP range to document range using prebuilt line starts. Clamps like `editorNSRange`, without rescanning `text`.
private func diagnosticNSRange(_ range: LSPRange, lineStarts: [Int], length: Int) -> NSRange {
    func offset(_ position: LSPPosition) -> Int {
        guard position.line < lineStarts.count else { return length }
        let lineStart = lineStarts[position.line]
        let lineEnd = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] - 1 : length
        return max(lineStart, min(lineStart + position.character, lineEnd))
    }
    let start = min(offset(range.start), length)
    let end = min(max(offset(range.end), start), length)
    return NSRange(location: start, length: end - start)
}

/// LSP range to document range, clamped to `text`.
private func editorNSRange(_ range: LSPRange, in text: String) -> NSRange {
    let length = (text as NSString).length
    let start = min(LSPText.utf16Offset(for: range.start, in: text), length)
    let end = min(max(LSPText.utf16Offset(for: range.end, in: text), start), length)
    return NSRange(location: start, length: end - start)
}

/// Tooltip-style panel for diagnostics and LSP hover text.
@MainActor
private final class EditorHoverPanel {
    private static let maxWidth: CGFloat = 500
    private static let padding: CGFloat = 8

    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private let box = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = box
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0x25 / 255.0, green: 0x25 / 255.0, blue: 0x26 / 255.0, alpha: 1).cgColor
        box.layer?.borderColor = NSColor(srgbRed: 0x45 / 255.0, green: 0x45 / 255.0, blue: 0x45 / 255.0, alpha: 1).cgColor
        box.layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(srgbRed: 0xCC / 255.0, green: 0xCC / 255.0, blue: 0xCC / 255.0, alpha: 1)
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        box.addSubview(label)
    }

    func show(_ text: String, above rect: NSRect, in view: NSView) {
        guard let window = view.window else { return }
        label.stringValue = text
        let textWidth = Self.maxWidth - 2 * Self.padding
        let fit = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)) ?? .zero
        let size = NSSize(
            width: min(Self.maxWidth, ceil(fit.width) + 2 * Self.padding),
            height: ceil(fit.height) + 2 * Self.padding
        )
        box.frame = NSRect(origin: .zero, size: size)
        label.frame = box.bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let screen = window.convertToScreen(view.convert(rect, to: nil))
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.setFrame(NSRect(origin: NSPoint(x: screen.minX, y: screen.maxY + 2), size: size), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

// MARK: - Line-start index helpers (PERF-MAC_FILES-016)

/// Build a sorted array of UTF-16 character offsets at which each line starts.
///
/// Entry 0 is always 0 (start of document = line 1).
/// Each subsequent entry is the UTF-16 offset of the character immediately following a `\n`.
/// Using NSString UTF-16 offsets keeps this consistent with NSLayoutManager character indices.
///
/// Complexity: O(n) in document length - called only when the document changes, not per paint.
nonisolated func buildLineStartOffsets(text: String) -> [Int] {
    let ns = text as NSString
    let length = ns.length
    var offsets = [0]
    var i = 0
    while i < length {
        let c = ns.character(at: i)
        i += 1
        if c == 0x0A { // '\n'
            offsets.append(i)
        }
    }
    return offsets
}

/// Return the 0-based line index (line 0 = first line) for a UTF-16 character offset,
/// using the prebuilt `offsets` array from `buildLineStartOffsets`.
///
/// Uses upper-bound binary search over the sorted offsets array: finds the last entry
/// whose value is <= `charOffset`, which is the line that contains that offset.
///
/// Complexity: O(log n) in line count.
nonisolated func lineIndex(forCharOffset charOffset: Int, in offsets: [Int]) -> Int {
    guard !offsets.isEmpty else { return 0 }
    var lo = 0
    var hi = offsets.count // exclusive upper bound
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if offsets[mid] <= charOffset {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    // lo is now the first index where offsets[lo] > charOffset,
    // so lo - 1 is the line that contains charOffset.
    return max(0, lo - 1)
}

private func highlightedHTML(text: String, language: String?) -> String {
    let html = text
        .components(separatedBy: "\n")
        .map(highlightCodeLine)
        .joined(separator: "\n")
    let css = """
    body { margin:0; background:#1e1e1e; color:#d4d4d4; font:12px ui-monospace, SFMono-Regular, Menlo, monospace; }
    pre { margin:0; padding:14px; white-space:pre-wrap; word-break:break-word; }
    ::selection { background:#264f78; }
    .comment { color:#6a9955; }
    .kw { color:#569cd6; }
    .control { color:#c586c0; }
    .type { color:#4ec9b0; }
    .str { color:#ce9178; }
    .num { color:#b5cea8; }
    .tag { color:#569cd6; }
    .attr, .prop { color:#9cdcfe; }
    .selector { color:#d7ba7d; }
    .punct { color:#808080; }
    """
    return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body><pre data-language=\"\(language ?? "text")\">\(html)</pre></body></html>"
}

/// Build NSAttributedString base attributes from a resolved palette so the editor and gutter
/// use consistent colors when the appearance changes (P2).
private func codeBaseAttributes(for palette: EditorColorPalette) -> [NSAttributedString.Key: Any] {
    [.font: EditorMetrics.font,
     .foregroundColor: palette.text,
     .paragraphStyle: EditorMetrics.paragraphStyle]
}

func highlightedCodeAttributedString(_ text: String, palette: EditorColorPalette) -> NSMutableAttributedString {
    let attributed = NSMutableAttributedString(string: text, attributes: codeBaseAttributes(for: palette))
    highlightCode(text, in: attributed)
    return attributed
}

private func highlightCode(_ text: String, in attributed: NSMutableAttributedString) {
    let nsText = text as NSString
    nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
        let line = nsText.substring(with: range)
        applyHighlightSpans(highlightCodeLine(line), lineRange: range, to: attributed)
    }
}

private func applyHighlightSpans(_ html: String, lineRange: NSRange, to attributed: NSMutableAttributedString) {
    var sourceIndex = html.startIndex
    var plainOffset = 0
    var activeClass: String?

    while sourceIndex < html.endIndex {
        if html[sourceIndex...].hasPrefix("<span class=\"") {
            let classStart = html.index(sourceIndex, offsetBy: 13)
            guard let classEnd = html[classStart...].firstIndex(of: "\""),
                  let tagEnd = html[classEnd...].firstIndex(of: ">") else { break }
            activeClass = String(html[classStart..<classEnd])
            sourceIndex = html.index(after: tagEnd)
            continue
        }
        if html[sourceIndex...].hasPrefix("</span>") {
            activeClass = nil
            sourceIndex = html.index(sourceIndex, offsetBy: 7)
            continue
        }

        let decoded: String
        if html[sourceIndex...].hasPrefix("&lt;") {
            decoded = "<"
            sourceIndex = html.index(sourceIndex, offsetBy: 4)
        } else if html[sourceIndex...].hasPrefix("&gt;") {
            decoded = ">"
            sourceIndex = html.index(sourceIndex, offsetBy: 4)
        } else if html[sourceIndex...].hasPrefix("&amp;") {
            decoded = "&"
            sourceIndex = html.index(sourceIndex, offsetBy: 5)
        } else {
            decoded = String(html[sourceIndex])
            sourceIndex = html.index(after: sourceIndex)
        }

        let length = (decoded as NSString).length
        if let activeClass, let color = codeColor(for: activeClass), length > 0 {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: lineRange.location + plainOffset, length: length))
        }
        plainOffset += length
    }
}

private func codeColor(for tokenClass: String) -> NSColor? {
    switch tokenClass {
    case "comment": return NSColor(red: 0.42, green: 0.60, blue: 0.33, alpha: 1)
    case "kw", "tag": return NSColor(red: 0.34, green: 0.61, blue: 0.84, alpha: 1)
    case "control": return NSColor(red: 0.77, green: 0.53, blue: 0.75, alpha: 1)
    case "type": return NSColor(red: 0.31, green: 0.79, blue: 0.69, alpha: 1)
    case "str": return NSColor(red: 0.81, green: 0.57, blue: 0.47, alpha: 1)
    case "num": return NSColor(red: 0.71, green: 0.81, blue: 0.66, alpha: 1)
    case "attr", "prop": return NSColor(red: 0.61, green: 0.86, blue: 1.0, alpha: 1)
    case "selector": return NSColor(red: 0.84, green: 0.73, blue: 0.49, alpha: 1)
    case "punct": return NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    default: return nil
    }
}

private let codeKeywords = Set(["class", "struct", "enum", "func", "let", "var", "import", "public", "private", "final", "async", "await", "throws", "try", "catch", "do", "in", "extension", "protocol", "init", "self", "static", "const", "function", "def", "from", "as", "nil", "null", "true", "false"])
private let controlKeywords = Set(["return", "if", "else", "for", "while", "guard", "case", "switch", "break", "continue", "throw"])

private func highlightCodeLine(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("<") {
        return highlightMarkupLine(line)
    }
    if looksLikeStyleLine(line) {
        return highlightStyleLine(line)
    }
    return highlightGeneralLine(line, hashStartsComment: true)
}

private func highlightMarkupLine(_ line: String) -> String {
    var output = ""
    var index = line.startIndex
    var inTag = false

    while index < line.endIndex {
        let char = line[index]
        let next = line.index(after: index)
        if line[index...].hasPrefix("<!--") {
            output += "<span class=\"comment\">\(htmlEscape(String(line[index...])))</span>"
            return output
        }
        if char == "<" {
            inTag = true
            output += "<span class=\"punct\">&lt;</span>"
            index = next
            if index < line.endIndex, line[index] == "/" {
                output += "<span class=\"punct\">/</span>"
                index = line.index(after: index)
            }
            if index < line.endIndex, isIdentifierStart(line[index]) {
                let end = scanIdentifier(in: line, from: index)
                output += "<span class=\"tag\">\(htmlEscape(String(line[index..<end])))</span>"
                index = end
            }
            continue
        }
        if char == ">" {
            inTag = false
            output += "<span class=\"punct\">&gt;</span>"
            index = next
            continue
        }
        if inTag, char == "\"" || char == "'" {
            let end = stringEnd(in: line, from: index, quote: char)
            output += "<span class=\"str\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            continue
        }
        if inTag, isIdentifierStart(char) {
            let end = scanIdentifier(in: line, from: index)
            output += "<span class=\"attr\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            continue
        }
        if inTag, char == "=" || char == "/" {
            output += "<span class=\"punct\">\(htmlEscape(String(char)))</span>"
            index = next
            continue
        }
        output += htmlEscape(String(char))
        index = next
    }
    return output
}

private func highlightStyleLine(_ line: String) -> String {
    if let open = line.firstIndex(of: "{") {
        let before = String(line[..<open])
        let after = String(line[line.index(after: open)...])
        return "<span class=\"selector\">\(htmlEscape(before))</span><span class=\"punct\">{</span>\(highlightStyleLine(after))"
    }
    if let close = line.firstIndex(of: "}") {
        let before = String(line[..<close])
        let after = String(line[line.index(after: close)...])
        return "\(highlightStyleLine(before))<span class=\"punct\">}</span>\(highlightStyleLine(after))"
    }
    if let colon = line.firstIndex(of: ":") {
        let before = String(line[..<colon])
        let after = String(line[line.index(after: colon)...])
        return "<span class=\"prop\">\(htmlEscape(before))</span><span class=\"punct\">:</span>\(highlightGeneralLine(after, hashStartsComment: false))"
    }
    return highlightGeneralLine(line, hashStartsComment: false)
}

private func highlightGeneralLine(_ line: String, hashStartsComment: Bool) -> String {
    var output = ""
    var index = line.startIndex
    var sawNonWhitespace = false

    while index < line.endIndex {
        let char = line[index]
        let next = line.index(after: index)
        if char == "/" && next < line.endIndex && line[next] == "/" {
            output += "<span class=\"comment\">\(htmlEscape(String(line[index...])))</span>"
            break
        }
        if hashStartsComment, char == "#" && !sawNonWhitespace {
            output += "<span class=\"comment\">\(htmlEscape(String(line[index...])))</span>"
            break
        }
        if char == "\"" || char == "'" {
            let end = stringEnd(in: line, from: index, quote: char)
            output += "<span class=\"str\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            sawNonWhitespace = true
            continue
        }
        if isIdentifierStart(char) {
            let end = scanIdentifier(in: line, from: index)
            let word = String(line[index..<end])
            if controlKeywords.contains(word) {
                output += "<span class=\"control\">\(word)</span>"
            } else if codeKeywords.contains(word) {
                output += "<span class=\"kw\">\(word)</span>"
            } else if word.first?.isUppercase == true {
                output += "<span class=\"type\">\(word)</span>"
            } else {
                output += htmlEscape(word)
            }
            index = end
            sawNonWhitespace = true
            continue
        }
        if char.isNumber {
            var end = next
            while end < line.endIndex && (line[end].isNumber || line[end] == "." || line[end] == "_") {
                end = line.index(after: end)
            }
            output += "<span class=\"num\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            sawNonWhitespace = true
            continue
        }
        output += htmlEscape(String(char))
        if !char.isWhitespace { sawNonWhitespace = true }
        index = next
    }
    return output
}

private func looksLikeStyleLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else { return false }
    return trimmed.contains("{") || trimmed.contains("}") || (trimmed.contains(":") && trimmed.hasSuffix(";"))
}

private func scanIdentifier(in line: String, from start: String.Index) -> String.Index {
    var end = line.index(after: start)
    while end < line.endIndex && isIdentifierPart(line[end]) {
        end = line.index(after: end)
    }
    return end
}

private func stringEnd(in line: String, from start: String.Index, quote: Character) -> String.Index {
    var index = line.index(after: start)
    var escaped = false
    while index < line.endIndex {
        let char = line[index]
        if escaped {
            escaped = false
        } else if char == "\\" {
            escaped = true
        } else if char == quote {
            return line.index(after: index)
        }
        index = line.index(after: index)
    }
    return line.endIndex
}

private func isIdentifierStart(_ char: Character) -> Bool {
    char == "_" || char.isLetter
}

private func isIdentifierPart(_ char: Character) -> Bool {
    char == "_" || char.isLetter || char.isNumber
}

private func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

private extension NSAppearance {
    /// Returns `true` when the effective appearance is a dark-aqua variant.
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
