import Foundation
import CryptoKit
import UniformTypeIdentifiers
import CoreModel
import Persistence

public enum WorkspaceFileLimits {
    public static let sampleBytes = 64 * 1024
    public static let readBytes = 2 * 1024 * 1024
    public static let editBytes = 2 * 1024 * 1024
    /// Head bytes returned when a file is too large to read in full.
    public static let previewHeadBytes = 32 * 1024
    /// Files larger than this are served as a preview instead of being read in full.
    public static let previewThresholdBytes = 512 * 1024
}

public enum ReadStrategy: Equatable {
    case full
    case preview(headBytes: Int)
}

/// Pure helper: decide read strategy from file size and cap.
/// Returns .preview when fileSize > cap; .full otherwise.
/// - Parameters:
///   - fileSize: Actual file size in bytes.
///   - cap: Threshold above which preview is used.
///   - headBytes: How many bytes to include in the preview head.
public func readStrategy(fileSize: Int64, cap: Int64, headBytes: Int = WorkspaceFileLimits.previewHeadBytes) -> ReadStrategy {
    fileSize > cap ? .preview(headBytes: headBytes) : .full
}

public struct WorkspaceFileService: Sendable {
    public init() {}

    public func list(root: String, path: String?) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let directory = try resolve(root: rootURL, path: path, mustExist: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "not a directory", data: .string(directory.path))
        }
        // Prefer name-only listing that skips stat on network-mount children of a
        // local parent (home workspaces + OrbStack NFS must not force TCC prompts).
        let listed = try HostSafeDirectoryListing.list(path: directory.path)
        let entries = listed.map { entry -> (Bool, String, JSONValue) in
            let child = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
            var values: URLResourceValues?
            if !entry.isNetworkVolume {
                values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                ])
            }
            return (entry.isDirectory, entry.name, .object(entryJSON(root: rootURL, url: child, values: values)))
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 && !rhs.0 }
            return lhs.1.localizedCaseInsensitiveCompare(rhs.1) == .orderedAscending
        }
        .map { $0.2 }
        return .object([
            "root": .string(rootURL.path),
            "path": .string(directory.path),
            "relative_path": .string(relativePath(root: rootURL, url: directory)),
            "parent_path": parentPath(root: rootURL, url: directory).map { .string($0) } ?? .null,
            "entries": .array(entries)
        ])
    }

    public func read(root: String, path: String, maxBytes: Int? = nil) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let file = try resolve(root: rootURL, path: path, mustExist: true)
        let identity = try classify(root: rootURL, path: file.path)
        guard identity.kind != "directory" else {
            throw JSONRPCError(code: -32602, message: "not a file", data: .string(file.path))
        }
        guard identity.isTextReadable else {
            return .object([
                "path": .string(file.path),
                "relative_path": .string(relativePath(root: rootURL, url: file)),
                "kind": .string(identity.kind),
                "mime": .string(identity.mime),
                "size": .number(Double(identity.size)),
                "encoding": .null,
                "content": .null,
                "truncated": .bool(false),
                "identity": identity.json
            ])
        }
        let limit = max(0, min(maxBytes ?? WorkspaceFileLimits.readBytes, WorkspaceFileLimits.readBytes))
        let strategy = readStrategy(
            fileSize: identity.size,
            cap: Int64(WorkspaceFileLimits.previewThresholdBytes)
        )
        switch strategy {
        case .preview(let headBytes):
            let headLimit = min(headBytes, limit)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: headLimit) ?? Data()
            let decoded = try decodeText(data)
            return .object([
                "path": .string(file.path),
                "relative_path": .string(relativePath(root: rootURL, url: file)),
                "kind": .string(identity.kind),
                "mime": .string(identity.mime),
                "size": .number(Double(identity.size)),
                "encoding": .string(decoded.encoding),
                "content": .string(decoded.text),
                "truncated": .bool(true),
                "preview": .bool(true),
                "identity": identity.json
            ])
        case .full:
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            let truncated = data.count > limit
            let clipped = truncated ? data.prefix(limit) : data[...]
            let decoded = try decodeText(Data(clipped))
            return .object([
                "path": .string(file.path),
                "relative_path": .string(relativePath(root: rootURL, url: file)),
                "kind": .string(identity.kind),
                "mime": .string(identity.mime),
                "size": .number(Double(identity.size)),
                "encoding": .string(decoded.encoding),
                "content": .string(decoded.text),
                "truncated": .bool(truncated),
                "preview": .bool(false),
                "identity": identity.json
            ])
        }
    }

    public func previewURL(root: String, path: String) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let file = try resolve(root: rootURL, path: path, mustExist: true)
        let identity = try classify(root: rootURL, path: file.path)
        guard previewKinds.contains(identity.kind),
              let grant = DirectStaticFileRegistry.shared.register(fileURL: file) else {
            throw JSONRPCError(code: -32602, message: "preview unavailable", data: .string(file.path))
        }
        return .object([
            "url_path": .string(grant.routePath),
            "mime": .string(identity.mime),
            "expires_at": .number(Date().addingTimeInterval(60 * 60).timeIntervalSince1970)
        ])
    }

    public func createFile(root: String, path: String, content: String = "") throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let file = try resolve(root: rootURL, path: path, mustExist: false)
        guard file.path != rootURL.path else {
            throw JSONRPCError(code: -32602, message: "file name required", data: .string(path))
        }
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw JSONRPCError(code: -32602, message: "file already exists", data: .string(relativePath(root: rootURL, url: file)))
        }
        let parent = file.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "parent directory not found", data: .string(relativePath(root: rootURL, url: parent)))
        }
        guard FileManager.default.createFile(atPath: file.path, contents: Data(content.utf8)) else {
            throw JSONRPCError(code: -32000, message: "file create failed", data: .string(relativePath(root: rootURL, url: file)))
        }
        return .object(entryJSON(root: rootURL, url: file))
    }

    public func rename(root: String, path: String, newName: String) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let source = try resolve(root: rootURL, path: path, mustExist: true)
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeLeafName(name) else {
            throw JSONRPCError(code: -32602, message: "invalid file name", data: .string(newName))
        }
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(name)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try ensureInside(root: rootURL, url: destination, requested: newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw JSONRPCError(code: -32602, message: "file already exists", data: .string(relativePath(root: rootURL, url: destination)))
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return .object(entryJSON(root: rootURL, url: destination))
    }

    public func createDirectory(root: String, path: String) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let dir = try resolve(root: rootURL, path: path, mustExist: false)
        guard dir.path != rootURL.path else {
            throw JSONRPCError(code: -32602, message: "directory name required", data: .string(path))
        }
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw JSONRPCError(code: -32602, message: "file already exists", data: .string(relativePath(root: rootURL, url: dir)))
        }
        let parent = dir.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "parent directory not found", data: .string(relativePath(root: rootURL, url: parent)))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return .object(entryJSON(root: rootURL, url: dir))
    }

    public func moveItem(root: String, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let source = try resolve(root: rootURL, path: sourcePath, mustExist: true)
        guard source.path != rootURL.path else {
            throw JSONRPCError(code: -32602, message: "cannot move workspace root", data: .string(sourcePath))
        }
        let destDir = try resolve(root: rootURL, path: destinationDirectoryPath, mustExist: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "destination is not a directory", data: .string(destinationDirectoryPath))
        }
        let destination = destDir.appendingPathComponent(source.lastPathComponent)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try ensureInside(root: rootURL, url: destination, requested: destinationDirectoryPath)
        // Reject moving a directory into itself or a descendant.
        let srcPath = source.path
        let dstPath = destination.path
        guard dstPath != srcPath,
              !dstPath.hasPrefix(srcPath + "/") else {
            throw JSONRPCError(code: -32602, message: "cannot move a directory into itself or a descendant", data: .string(sourcePath))
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw JSONRPCError(code: -32602, message: "destination already exists", data: .string(relativePath(root: rootURL, url: destination)))
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return .object(entryJSON(root: rootURL, url: destination))
    }

    public func delete(root: String, paths: [String]) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        guard !paths.isEmpty else {
            throw JSONRPCError(code: -32602, message: "file path required")
        }
        var seen = Set<String>()
        var targets: [(url: URL, relative: String)] = []
        for path in paths {
            let file = try resolve(root: rootURL, path: path, mustExist: true)
            guard file.path != rootURL.path else {
                throw JSONRPCError(code: -32602, message: "cannot delete workspace root", data: .string(path))
            }
            guard seen.insert(file.path).inserted else { continue }
            targets.append((file, relativePath(root: rootURL, url: file)))
        }

        for target in targets.sorted(by: { $0.url.path.count > $1.url.path.count }) {
            try FileManager.default.removeItem(at: target.url)
        }
        return .object([
            "deleted": .array(targets.map { .string($0.relative) }),
            "count": .number(Double(targets.count))
        ])
    }

    public func classify(root: String, path: String) throws -> FileIdentity {
        try classify(root: try safeRoot(root), path: path)
    }

    public func resolvePath(root: String, path: String?, mustExist: Bool = true) throws -> String {
        try resolve(root: safeRoot(root), path: path, mustExist: mustExist).path
    }

    private func classify(root: URL, path: String) throws -> FileIdentity {
        let file = try resolve(root: root, path: path, mustExist: true)
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: file.path)
        let type = attrs[.type] as? FileAttributeType
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs[.modificationDate] as? Date
        let ext = file.pathExtension.lowercased()
        if type == .typeDirectory {
            return FileIdentity(kind: "directory", mime: "inode/directory", uti: "public.folder", ext: ext, size: size, modifiedAt: modified, isBinary: false, isTextReadable: false, isEditable: false, editabilityReason: "directory", language: nil)
        }
        let sample = try readSample(file: file)
        let probe = TextProbe(data: sample)
        let magic = MagicKind(data: sample, ext: ext)
        let uti = UTType(filenameExtension: ext)
        let language = languageName(ext: ext)
        let kind: String
        if let magicKind = magic.kind {
            kind = magicKind
        } else if ext == "md" || ext == "markdown" {
            kind = "markdown"
        } else if ext == "html" || ext == "htm" {
            kind = "html"
        } else if language != nil {
            kind = "code"
        } else if imageExtensions.contains(ext) {
            kind = "image"
        } else if videoExtensions.contains(ext) {
            kind = "video"
        } else if ext == "pdf" {
            kind = "pdf"
        } else if probe.isText || sample.isEmpty {
            kind = "text"
        } else {
            kind = "binary"
        }
        let isText = textKinds.contains(kind) && probe.canDecode
        let writable = fm.isWritableFile(atPath: file.path)
        let isEditable = isText && size <= Int64(WorkspaceFileLimits.editBytes) && writable
        let reason: String
        if isEditable {
            reason = "editable \(kind)"
        } else if !isText {
            reason = kind == "binary" ? "binary or unknown file" : "\(kind) preview is read-only"
        } else if size > Int64(WorkspaceFileLimits.editBytes) {
            reason = "file is too large to edit"
        } else if !writable {
            reason = "file is not writable"
        } else {
            reason = "not editable"
        }
        return FileIdentity(
            kind: kind,
            mime: magic.mime ?? uti?.preferredMIMEType ?? fallbackMIME(ext: ext, kind: kind),
            uti: uti?.identifier,
            ext: ext,
            size: size,
            modifiedAt: modified,
            isBinary: !isText && kind != "directory",
            isTextReadable: isText,
            isEditable: isEditable,
            editabilityReason: reason,
            language: kind == "markdown" ? "markdown" : (kind == "html" ? "html" : language)
        )
    }

    private func safeRoot(_ root: String) throws -> URL {
        let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "workspace root not found", data: .string(root))
        }
        return url
    }

    private func resolve(root: URL, path: String?, mustExist: Bool) throws -> URL {
        let requested = path?.isEmpty == false ? path! : root.path
        let candidate: URL
        if requested.hasPrefix("/") || requested.hasPrefix("~") {
            candidate = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath)
        } else {
            candidate = root.appendingPathComponent(requested)
        }
        let standardized = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else {
            throw JSONRPCError(code: -32602, message: "path escapes workspace", data: .string(requested))
        }
        if mustExist && !FileManager.default.fileExists(atPath: standardized.path) {
            throw JSONRPCError(code: -32602, message: "not found", data: .string(standardized.path))
        }
        return standardized
    }

    private func ensureInside(root: URL, url: URL, requested: String) throws {
        let rootPath = root.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw JSONRPCError(code: -32602, message: "path escapes workspace", data: .string(requested))
        }
    }

    private func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }

    /// Cheap classification from extension + metadata only. No file bytes are read.
    /// Used for directory listings where reading every child's content is wasteful.
    /// The full content-based classify() is used on read/open.
    private func classifyByExtension(url: URL, size: Int64, modifiedAt: Date?, isSymlink: Bool) -> FileIdentity {
        let ext = url.pathExtension.lowercased()
        let uti = UTType(filenameExtension: ext)
        let language = languageName(ext: ext)
        let kind: String
        if ext == "md" || ext == "markdown" {
            kind = "markdown"
        } else if ext == "html" || ext == "htm" {
            kind = "html"
        } else if language != nil {
            kind = "code"
        } else if imageExtensions.contains(ext) {
            kind = "image"
        } else if videoExtensions.contains(ext) {
            kind = "video"
        } else if ext == "pdf" {
            kind = "pdf"
        } else if let utiVal = uti, utiVal.conforms(to: .text) {
            kind = "text"
        } else {
            kind = "unknown"
        }
        let isText = textKinds.contains(kind)
        let writable = FileManager.default.isWritableFile(atPath: url.path)
        let isEditable = isText && size <= Int64(WorkspaceFileLimits.editBytes) && writable
        let reason: String
        if isEditable {
            reason = "editable \(kind)"
        } else if isSymlink {
            reason = "symlink outside workspace or unreadable"
        } else if !isText {
            reason = kind == "unknown" ? "binary or unknown file" : "\(kind) preview is read-only"
        } else if size > Int64(WorkspaceFileLimits.editBytes) {
            reason = "file is too large to edit"
        } else if !writable {
            reason = "file is not writable"
        } else {
            reason = "not editable"
        }
        return FileIdentity(
            kind: kind,
            mime: uti?.preferredMIMEType ?? fallbackMIME(ext: ext, kind: kind),
            uti: uti?.identifier,
            ext: ext,
            size: size,
            modifiedAt: modifiedAt,
            isBinary: !isText,
            isTextReadable: isText,
            isEditable: isEditable,
            editabilityReason: reason,
            language: kind == "markdown" ? "markdown" : (kind == "html" ? "html" : language)
        )
    }

    private func entryJSON(root: URL, url: URL, values: URLResourceValues? = nil) -> [String: JSONValue] {
        let resourceValues: URLResourceValues?
        if let values {
            resourceValues = values
        } else {
            resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        }
        let isDirectory = resourceValues?.isDirectory == true
        let size = Int64(resourceValues?.fileSize ?? 0)
        let modifiedAt = resourceValues?.contentModificationDate
        let isSymlink = resourceValues?.isSymbolicLink == true
        let identity: FileIdentity
        let ext = url.pathExtension.lowercased()
        if isDirectory {
            identity = FileIdentity(
                kind: "directory",
                mime: "inode/directory",
                uti: "public.folder",
                ext: ext,
                size: size,
                modifiedAt: modifiedAt,
                isBinary: false,
                isTextReadable: false,
                isEditable: false,
                editabilityReason: "directory",
                language: nil
            )
        } else {
            identity = classifyByExtension(url: url, size: size, modifiedAt: modifiedAt, isSymlink: isSymlink)
        }
        return [
            "name": .string(url.lastPathComponent),
            "path": .string(url.path),
            "relative_path": .string(relativePath(root: root, url: url)),
            "type": .string(isDirectory ? "directory" : "file"),
            "ext": .string(ext),
            "size": .number(Double(identity.size)),
            "modified_at": identity.modifiedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "is_hidden": .bool(url.lastPathComponent.hasPrefix(".")),
            "is_symlink": .bool(isSymlink),
            "identity": identity.json
        ]
    }

    private func readSample(file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: WorkspaceFileLimits.sampleBytes) ?? Data()
    }

    private func relativePath(root: URL, url: URL) -> String {
        let rootPath = canonicalPath(root)
        let urlPath = canonicalPath(url)
        guard urlPath != rootPath else { return "" }
        guard urlPath.hasPrefix(rootPath + "/") else { return String(url.path.dropFirst(root.path.count + 1)) }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    private func parentPath(root: URL, url: URL) -> String? {
        guard canonicalPath(url) != canonicalPath(root) else { return nil }
        return relativePath(root: root, url: url.deletingLastPathComponent())
    }

    private func canonicalPath(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            ?? url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct FileIdentity: Sendable, Equatable {
    public let kind: String
    public let mime: String
    public let uti: String?
    public let ext: String
    public let size: Int64
    public let modifiedAt: Date?
    public let isBinary: Bool
    public let isTextReadable: Bool
    public let isEditable: Bool
    public let editabilityReason: String
    public let language: String?

    public var json: JSONValue {
        .object([
            "kind": .string(kind),
            "mime": .string(mime),
            "uti": uti.map { .string($0) } ?? .null,
            "ext": .string(ext),
            "size": .number(Double(size)),
            "modified_at": modifiedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "is_binary": .bool(isBinary),
            "is_text_readable": .bool(isTextReadable),
            "is_editable": .bool(isEditable),
            "editability_reason": .string(editabilityReason),
            "language": language.map { .string($0) } ?? .null
        ])
    }
}

public final class FileEditSessionStore: @unchecked Sendable {
    public static let shared = FileEditSessionStore()

    private struct Session {
        var id: String
        var surfaceID: SurfaceID
        var workspaceID: WorkspaceID
        var root: String
        var path: String
        var relativePath: String
        var baseHash: String
        var baseModifiedAt: Date?
        /// QA-002: records when the session was opened via the injectable clock
        /// so time-dependent paths (session age, future TTL expiry) are testable
        /// without a real delay.
        var openedAt: Date
        var draftRevision: Int
        var draftText: String
        var encoding: String
        var language: String?
        var dirty: Bool
        var activeWriterDevice: String?
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private let service = WorkspaceFileService()
    // QA-002: injectable clock so session openedAt and any future TTL paths are
    // deterministically testable. Default is real wall time. Protected by `lock`.
    private var clock: @Sendable () -> Date = { Date() }

    /// QA-002: inject a fixed or advancing clock so session-timing paths are
    /// deterministic. Must not be called in production code.
    public func setClockForTests(_ clock: @escaping @Sendable () -> Date) {
        lock.lock(); defer { lock.unlock() }
        self.clock = clock
    }

    private func currentTime() -> Date {
        lock.lock(); defer { lock.unlock() }
        return clock()
    }

    public func open(surfaceID: SurfaceID, workspaceID: WorkspaceID, root: String, path: String) throws -> JSONValue {
        let read = try service.read(root: root, path: path, maxBytes: WorkspaceFileLimits.editBytes)
        guard let body = read.objectValue,
              let identity = body["identity"]?.objectValue,
              identity["is_editable"]?.boolValue == true,
              let content = body["content"]?.stringValue,
              let absPath = body["path"]?.stringValue,
              let relPath = body["relative_path"]?.stringValue else {
            let reason = read.objectValue?["identity"]?.objectValue?["editability_reason"]?.stringValue ?? "file is not editable"
            throw JSONRPCError(code: -32602, message: reason, data: read)
        }
        let encoding = body["encoding"]?.stringValue ?? "utf-8"
        let data = try readEditableFileData(path: absPath)
        let id = UUID().uuidString
        let session = Session(
            id: id,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            root: root,
            path: absPath,
            relativePath: relPath,
            baseHash: hash(data),
            baseModifiedAt: (try? FileManager.default.attributesOfItem(atPath: absPath)[.modificationDate]) as? Date,
            openedAt: currentTime(),
            draftRevision: 1,
            draftText: content,
            encoding: encoding,
            language: identity["language"]?.stringValue,
            dirty: false,
            activeWriterDevice: nil
        )
        lock.lock()
        // Mac and paired devices edit one host draft for each open document.
        // Reopening must not replace an unsaved draft with the disk contents.
        let active = sessions.values.first {
            $0.surfaceID == surfaceID && $0.workspaceID == workspaceID && $0.path == absPath && $0.root == root
        } ?? session
        sessions[active.id] = active
        lock.unlock()
        let payload = sessionJSON(active, includeContent: true)
        EventBus.shared.publish(kind: .filesEditOpened, payload: .object(payload))
        return .object(payload)
    }

    public func applyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        lock.lock()
        guard var session = sessions[sessionID] else {
            lock.unlock()
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        guard session.draftRevision == baseDraftRevision else {
            let payload = sessionJSON(session, includeContent: true)
            lock.unlock()
            throw JSONRPCError(code: -32012, message: "draft revision conflict", data: .object(payload))
        }
        guard let range = Range(NSRange(location: rangeLocation, length: rangeLength), in: session.draftText) else {
            lock.unlock()
            throw JSONRPCError.invalidParams
        }
        session.draftText.replaceSubrange(range, with: replacement)
        session.draftRevision += 1
        session.dirty = true
        session.activeWriterDevice = deviceID
        sessions[sessionID] = session
        let payload = sessionJSON(session, includeContent: true, patch: [
            "range_utf16": .object(["location": .number(Double(rangeLocation)), "length": .number(Double(rangeLength))]),
            "replacement": .string(replacement)
        ], updatedBy: deviceID)
        lock.unlock()
        EventBus.shared.publish(kind: .filesEditPatchApplied, payload: .object(payload))
        return .object(payload)
    }

    public func save(sessionID: String) throws -> JSONValue {
        lock.lock()
        var lockHeld = true
        defer {
            if lockHeld { lock.unlock() }
        }
        guard var session = sessions[sessionID] else {
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        let currentData = try readEditableFileData(path: session.path)
        guard hash(currentData) == session.baseHash else {
            let payload = sessionJSON(session, includeContent: true)
            lockHeld = false
            lock.unlock()
            EventBus.shared.publish(kind: .filesEditConflict, payload: .object(payload.merging(["reason": .string("disk_changed")]) { _, new in new }))
            throw JSONRPCError(code: -32013, message: "disk changed", data: .object(payload))
        }
        let data = encodeText(session.draftText, encoding: session.encoding)
        try atomicWrite(data, to: URL(fileURLWithPath: session.path))
        session.baseHash = hash(data)
        session.baseModifiedAt = (try? FileManager.default.attributesOfItem(atPath: session.path)[.modificationDate]) as? Date
        session.dirty = false
        sessions[sessionID] = session
        let payload = sessionJSON(session, includeContent: true).merging(["disk_hash": .string("sha256:\(session.baseHash)")]) { _, new in new }
        lockHeld = false
        lock.unlock()
        EventBus.shared.publish(kind: .filesEditSaved, payload: .object(payload))
        return .object(payload)
    }

    public func discard(sessionID: String) throws -> JSONValue {
        lock.lock()
        guard var session = sessions[sessionID] else {
            lock.unlock()
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        do {
            let data = try readEditableFileData(path: session.path)
            let decoded = try decodeText(data)
            session.draftText = decoded.text
            session.encoding = decoded.encoding
            session.baseHash = hash(data)
            session.draftRevision += 1
            session.dirty = false
            sessions[sessionID] = session
            let payload = sessionJSON(session, includeContent: true)
            lock.unlock()
            EventBus.shared.publish(kind: .filesEditDiscarded, payload: .object(payload))
            return .object(payload)
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func close(sessionID: String) throws -> JSONValue {
        lock.lock()
        let removed = sessions.removeValue(forKey: sessionID)
        lock.unlock()
        guard let removed else {
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        let payload = sessionJSON(removed, includeContent: false)
        EventBus.shared.publish(kind: .filesEditClosed, payload: .object(payload))
        return .object(payload)
    }

    public func session(sessionID: String) -> JSONValue? {
        lock.lock()
        let session = sessions[sessionID]
        lock.unlock()
        return session.map { .object(sessionJSON($0, includeContent: true)) }
    }

    /// Clears all sessions and resets the clock to real wall time.
    /// Call from test tearDown to prevent state bleeding between tests.
    public func resetForTests() {
        lock.lock()
        sessions.removeAll()
        clock = { Date() }
        lock.unlock()
    }

    private func readEditableFileData(path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: WorkspaceFileLimits.editBytes + 1) ?? Data()
        guard data.count <= WorkspaceFileLimits.editBytes else {
            throw JSONRPCError(code: -32602, message: "file is too large to edit", data: .string(path))
        }
        return data
    }

    private func sessionJSON(_ s: Session, includeContent: Bool, patch: [String: JSONValue]? = nil, updatedBy: String? = nil) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "session_id": .string(s.id),
            "surface_id": .string(s.surfaceID.value.uuidString),
            "workspace_id": .string(s.workspaceID.value.uuidString),
            "path": .string(s.relativePath),
            "absolute_path": .string(s.path),
            "draft_revision": .number(Double(s.draftRevision)),
            "dirty": .bool(s.dirty),
            "encoding": .string(s.encoding),
            "language": s.language.map { .string($0) } ?? .null,
            "opened_at": .number(s.openedAt.timeIntervalSince1970)
        ]
        if includeContent { payload["content"] = .string(s.draftText) }
        if let patch { payload["patch"] = .object(patch) }
        if let updatedBy { payload["updated_by_device"] = .string(updatedBy) }
        return payload
    }
}

private struct MagicKind {
    let kind: String?
    let mime: String?

    // PERF: static magic signatures — was allocating Data("GIF…"/ "%PDF") per probe.
    private static let gif87a: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]
    private static let gif89a: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
    private static let pdf: [UInt8] = [0x25, 0x50, 0x44, 0x46] // %PDF

    init(data: Data, ext: String) {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = "image"; mime = "image/png"; return }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { kind = "image"; mime = "image/jpeg"; return }
        if bytes.starts(with: Self.gif87a) || bytes.starts(with: Self.gif89a) {
            kind = "image"; mime = "image/gif"; return
        }
        if bytes.starts(with: Self.pdf) { kind = "pdf"; mime = "application/pdf"; return }
        if data.count >= 12, data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            kind = "image"; mime = "image/webp"; return
        }
        if data.count >= 12, String(data: data[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(data: data[8..<min(data.count, 16)], encoding: .ascii) ?? ""
            if brand.contains("heic") || brand.contains("avif") {
                kind = "image"; mime = ext == "avif" ? "image/avif" : "image/heic"; return
            }
            kind = "video"; mime = ext == "mov" ? "video/quicktime" : "video/mp4"; return
        }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { kind = "video"; mime = "video/webm"; return }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x1F, 0x8B]) {
            kind = "binary"; mime = "application/octet-stream"; return
        }
        kind = nil
        mime = nil
    }
}

private struct TextProbe {
    let isText: Bool
    let canDecode: Bool

    init(data: Data) {
        guard !data.isEmpty else {
            isText = true
            canDecode = true
            return
        }
        let nulCount = data.filter { $0 == 0 }.count
        if nulCount > max(2, data.count / 10) {
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || decodeLikelyUTF16(data) != nil {
                isText = true
                canDecode = true
            } else {
                isText = false
                canDecode = false
            }
            return
        }
        guard String(data: data, encoding: .utf8) != nil else {
            isText = false
            canDecode = false
            return
        }
        let printable = data.filter { byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte != 0x7F)
        }.count
        isText = Double(printable) / Double(max(data.count, 1)) > 0.85
        canDecode = isText
    }
}

private let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp", "svg", "avif"])
private let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])
// PERF: classify/preview run on Files surface open/list/RPC. Array-literal
// membership and the language map rebuilt per call; share process-wide tables
// (kind/extension membership contract unchanged).
private let textKinds: Set<String> = ["markdown", "html", "code", "text"]
private let previewKinds: Set<String> = ["html", "image", "video", "pdf"]
private let languageNamesByExtension: [String: String] = [
    "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript", "jsx": "javascript",
    "py": "python", "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml",
    "xml": "xml", "css": "css", "scss": "scss", "sh": "shell", "bash": "shell",
    "zsh": "shell", "sql": "sql", "log": "log", "txt": "text", "c": "c", "h": "c",
    "cpp": "cpp", "hpp": "cpp", "rs": "rust", "go": "go", "rb": "ruby", "php": "php",
]

private func languageName(ext: String) -> String? {
    languageNamesByExtension[ext]
}

private func fallbackMIME(ext: String, kind: String) -> String {
    switch kind {
    case "markdown": return "text/markdown; charset=utf-8"
    case "html": return "text/html; charset=utf-8"
    case "code", "text": return "text/plain; charset=utf-8"
    case "image": return "image/\(ext == "jpg" ? "jpeg" : ext)"
    case "video": return ext == "mov" ? "video/quicktime" : "video/\(ext)"
    case "pdf": return "application/pdf"
    default: return "application/octet-stream"
    }
}

private func decodeText(_ data: Data) throws -> (text: String, encoding: String) {
    if data.starts(with: [0xFF, 0xFE]) {
        let body = data.dropFirst(2)
        if let s = String(data: body, encoding: .utf16LittleEndian) { return (s, "utf-16le") }
    }
    if data.starts(with: [0xFE, 0xFF]) {
        let body = data.dropFirst(2)
        if let s = String(data: body, encoding: .utf16BigEndian) { return (s, "utf-16be") }
    }
    if let decoded = decodeLikelyUTF16(data) { return decoded }
    if let s = String(data: data, encoding: .utf8) { return (s, "utf-8") }
    throw JSONRPCError(code: -32602, message: "text decoding failed")
}

private func decodeLikelyUTF16(_ data: Data) -> (text: String, encoding: String)? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data.prefix(WorkspaceFileLimits.sampleBytes))
    let evenNuls = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
    let oddNuls = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
    let pairs = max(bytes.count / 2, 1)
    if Double(oddNuls) / Double(pairs) > 0.6,
       let text = String(data: data, encoding: .utf16LittleEndian),
       utf16PrintableRatio(text) > 0.85 {
        return (text, "utf-16le")
    }
    if Double(evenNuls) / Double(pairs) > 0.6,
       let text = String(data: data, encoding: .utf16BigEndian),
       utf16PrintableRatio(text) > 0.85 {
        return (text, "utf-16be")
    }
    return nil
}

private func utf16PrintableRatio(_ text: String) -> Double {
    guard !text.isEmpty else { return 1 }
    let printable = text.unicodeScalars.filter { scalar in
        scalar == "\t" || scalar == "\n" || scalar == "\r" || (!CharacterSet.controlCharacters.contains(scalar) && scalar.value >= 0x20)
    }.count
    return Double(printable) / Double(max(text.unicodeScalars.count, 1))
}

private func encodeText(_ text: String, encoding: String) -> Data {
    switch encoding {
    case "utf-16le":
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return data
    case "utf-16be":
        var data = Data([0xFE, 0xFF])
        data.append(text.data(using: .utf16BigEndian) ?? Data())
        return data
    default:
        return text.data(using: .utf8) ?? Data()
    }
}

/// Lowercase SHA-256 hex used for file-edit CAS (`baseHash` / `disk_hash`).
///
/// PERF: nibble table instead of per-byte `String(format:)` so multi-MB open /
/// save / conflict checks avoid 32 formatter calls per digest while keeping
/// the same CryptoKit lowercase hex contract.
func workspaceFileSHA256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    var out: [UInt8] = []
    out.reserveCapacity(64)
    let alphabet = workspaceFileHexNibbleAlphabet
    for byte in digest {
        out.append(alphabet[Int(byte >> 4)])
        out.append(alphabet[Int(byte & 0x0f)])
    }
    return String(bytes: out, encoding: .utf8) ?? ""
}

private let workspaceFileHexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

private func hash(_ data: Data) -> String {
    workspaceFileSHA256Hex(data)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: tmp, options: .atomic)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}
