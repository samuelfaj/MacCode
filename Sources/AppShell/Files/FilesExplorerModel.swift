import AppKit
import CoreServices
import CoreModel
import SocketServer

/// Git state shown on Explorer rows. Colors follow VS Code's dark defaults.
enum ExplorerGitStatus: Equatable {
    case modified, added, untracked, deleted, conflicted, ignored
    /// Folder that contains changed descendants.
    case containsChanges

    var badge: String? {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .deleted: return "D"
        case .conflicted: return "!"
        case .ignored, .containsChanges: return nil
        }
    }

    /// vscode: extensions/git/package.json gitDecoration.*ResourceForeground (dark).
    var colorHex: UInt32 {
        switch self {
        case .modified, .containsChanges: return 0xE2C08D
        case .added: return 0x81B88B
        case .untracked: return 0x73C991
        case .deleted: return 0xC74E39
        case .conflicted: return 0xE4676B
        case .ignored: return 0x8C8C8C
        }
    }
}

/// Parses `git status --porcelain=v1 -z` output into workspace-relative statuses.
/// `prefix` is `git rev-parse --show-prefix` (the workspace's path inside the repo, with a
/// trailing slash, or empty). Paths outside the workspace are dropped. Every ancestor folder of
/// a changed path is marked `.containsChanges`.
func parseGitPorcelain(_ output: String, prefix: String) -> [String: ExplorerGitStatus] {
    var result: [String: ExplorerGitStatus] = [:]
    let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var index = 0
    while index < records.count {
        let record = records[index]
        index += 1
        guard record.count > 3 else { continue }
        let x = record[record.startIndex]
        let y = record[record.index(after: record.startIndex)]
        var path = String(record.dropFirst(3))
        // Renames and copies carry the original path as the next record.
        if x == "R" || x == "C" { index += 1 }
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix(prefix) else { continue }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty else { continue }
        let status: ExplorerGitStatus
        switch (x, y) {
        case ("?", "?"): status = .untracked
        case ("!", "!"): status = .ignored
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = .conflicted
        case ("A", _): status = .added
        case ("D", _), (_, "D"): status = .deleted
        default: status = .modified
        }
        result[relative] = status
        guard status != .ignored else { continue }
        var parent = (relative as NSString).deletingLastPathComponent
        while !parent.isEmpty, parent != "." {
            if result[parent] == nil { result[parent] = .containsChanges }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }
    return result
}

/// Runs git off the main thread; returns nil when the folder is not a repository.
func readGitStatuses(root: String) -> [String: ExplorerGitStatus]? {
    func run(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    guard let prefix = run(["rev-parse", "--show-prefix"])?.trimmingCharacters(in: .whitespacesAndNewlines),
          let status = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return nil }
    return parseGitPorcelain(status, prefix: prefix)
}

/// FSEvents stream over the workspace root. Callbacks arrive on the main queue with the
/// workspace-relative directories that changed.
final class ExplorerFileWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let onChange: (Set<String>) -> Void

    init?(root: String, onChange: @escaping (Set<String>) -> Void) {
        self.root = (root as NSString).standardizingPath
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ExplorerFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [self.root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        var dirs = Set<String>()
        // FSEvents reports /private/var for /var roots.
        let roots = [root, "/private" + root]
        for raw in paths {
            let path = (raw as NSString).standardizingPath
            guard let base = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let relative = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative == ".git" || relative.hasPrefix(".git/") {
                dirs.insert(".git")
                continue
            }
            dirs.insert((relative as NSString).deletingLastPathComponent)
        }
        if !dirs.isEmpty { onChange(dirs) }
    }
}

extension FilesViewModel {
    /// Folder new items go into: the given selection's folder, a file's parent, else the root.
    func explorerTargetDirectory(for entry: FileEntry?) -> String {
        guard let entry else { return currentDirectory }
        if entry.isDirectory { return entry.relativePath }
        let parent = (entry.relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    /// Re-list loaded directories without losing expansion or selection. `directories` limits the
    /// refresh to those paths (and the root); nil refreshes everything loaded.
    func refreshTree(directories: Set<String>? = nil) {
        let loaded = Set(treeStore.cachedDirectoryPaths)
        let targets = directories.map { $0.intersection(loaded) } ?? loaded
        for path in targets {
            treeStore.invalidate(path: path)
            _ = treeStore.children(at: path)
        }
        if directories == nil || directories!.contains(currentDirectory) {
            if let result = try? router?.fsWorkspaceList(workspace: workspaceID, path: currentDirectory) {
                entries = mapEntries(result)
                treeStore.replaceRoots(entries)
            }
        }
        // Drop expansion for folders that no longer exist.
        let alive = expandedPaths.filter { path in
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(path))
        }
        if alive != expandedPaths { expandedPaths = alive }
        treeRevision &+= 1
        refreshGitStatus()
    }

    func scheduleExpansionPersist() {
        guard !restoringExpansion else { return }
        expansionPersistTimer?.invalidate()
        expansionPersistTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistExpansionNow() }
        }
    }

    func persistExpansionNow() {
        expansionPersistTimer = nil
        _ = try? router?.filesStateUpdate(surface: surfaceID, patch: [
            "expanded_dirs": .array(expandedPaths.sorted().map { JSONValue.string($0) })
        ], baseRevision: nil, deviceID: "mac-local")
    }

    /// Re-expand persisted folders that still exist, parents first.
    func restoreExpansion(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        restoringExpansion = true
        defer { restoringExpansion = false }
        var restored = Set<String>()
        for path in paths.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            let absolute = (root as NSString).appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir), isDir.boolValue else { continue }
            _ = treeStore.children(at: path)
            restored.insert(path)
        }
        expandedPaths = restored
        treeRevision &+= 1
    }

    func startExplorerWatching() {
        guard fileWatcher == nil, FileManager.default.fileExists(atPath: root) else { return }
        fileWatcher = ExplorerFileWatcher(root: root) { [weak self] dirs in
            MainActor.assumeIsolated {
                guard let self else { return }
                if dirs == [".git"] {
                    self.refreshGitStatus()
                } else {
                    self.refreshTree(directories: dirs.subtracting([".git"]))
                }
            }
        }
        refreshGitStatus()
    }

    /// Latest-wins git refresh; stale results are discarded.
    func refreshGitStatus() {
        gitGeneration &+= 1
        let generation = gitGeneration
        let root = self.root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statuses = readGitStatuses(root: root) ?? [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.gitGeneration == generation else { return }
                    if self.gitStatuses != statuses { self.gitStatuses = statuses }
                }
            }
        }
    }
}
