import Foundation
import Darwin

public enum GitFileStatus: String, Codable, Sendable, Equatable {
    case added, modified, deleted, renamed, copied, untracked, unknown
}

public struct GitFileEntry: Codable, Sendable, Equatable {
    public let path: String
    public let oldPath: String?
    public let status: GitFileStatus
    public let additions: Int
    public let deletions: Int
    public let binary: Bool

    public init(path: String, oldPath: String?, status: GitFileStatus, additions: Int, deletions: Int, binary: Bool) {
        self.path = path; self.oldPath = oldPath; self.status = status
        self.additions = additions; self.deletions = deletions; self.binary = binary
    }
}

public struct GitSummary: Codable, Sendable, Equatable {
    public let isGitRepo: Bool
    public let branch: String?
    public let dirty: Bool
    public let files: [GitFileEntry]
    public let totalAdditions: Int
    public let totalDeletions: Int

    public init(isGitRepo: Bool, branch: String?, dirty: Bool, files: [GitFileEntry], totalAdditions: Int, totalDeletions: Int) {
        self.isGitRepo = isGitRepo; self.branch = branch; self.dirty = dirty
        self.files = files; self.totalAdditions = totalAdditions; self.totalDeletions = totalDeletions
    }
}

public struct GitBranches: Codable, Sendable, Equatable {
    public let current: String?
    public let locals: [String]

    public init(current: String?, locals: [String]) {
        self.current = current; self.locals = locals
    }
}

public struct GitCommit: Codable, Sendable, Equatable {
    public let hash: String
    public let shortHash: String
    public let author: String
    public let date: String
    public let subject: String

    public init(hash: String, shortHash: String, author: String, date: String, subject: String) {
        self.hash = hash; self.shortHash = shortHash; self.author = author
        self.date = date; self.subject = subject
    }
}

public struct GitActionResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok; self.message = message
    }
}

public struct GitPullRequestRef: Codable, Sendable, Equatable {
    public let host: String
    public let repositoryPath: String
    public let number: Int
    public let remoteRef: String
    public let webURL: String

    public init(host: String, repositoryPath: String, number: Int, remoteRef: String, webURL: String) {
        self.host = host
        self.repositoryPath = repositoryPath
        self.number = number
        self.remoteRef = remoteRef
        self.webURL = webURL
    }
}

public struct GitPullRequestPreparation: Codable, Sendable, Equatable {
    public let ref: GitPullRequestRef
    public let worktreePath: String
    public let branch: String
    public let result: GitActionResult

    public init(ref: GitPullRequestRef, worktreePath: String, branch: String, result: GitActionResult) {
        self.ref = ref
        self.worktreePath = worktreePath
        self.branch = branch
        self.result = result
    }
}

public enum GitDeliveryPhaseStatus: String, Codable, Sendable, Equatable {
    case ready
    case blocked
    case completed
    case failed
    case skipped
}

public struct GitDeliveryPhase: Codable, Sendable, Equatable {
    public let name: String
    public let status: GitDeliveryPhaseStatus
    public let detail: String

    public init(name: String, status: GitDeliveryPhaseStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct GitDeliveryPlan: Codable, Sendable, Equatable {
    public let branchName: String
    public let commitMessage: String
    public let pullRequestTitle: String
    public let pullRequestBody: String
    public let pullRequestURL: String?
    public let phases: [GitDeliveryPhase]

    public init(branchName: String, commitMessage: String, pullRequestTitle: String, pullRequestBody: String, pullRequestURL: String?, phases: [GitDeliveryPhase]) {
        self.branchName = branchName
        self.commitMessage = commitMessage
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestBody = pullRequestBody
        self.pullRequestURL = pullRequestURL
        self.phases = phases
    }
}

public struct GitDeliveryCopy: Codable, Sendable, Equatable {
    public let branchName: String?
    public let commitMessage: String?
    public let pullRequestTitle: String?
    public let pullRequestBody: String?

    public init(branchName: String? = nil, commitMessage: String? = nil, pullRequestTitle: String? = nil, pullRequestBody: String? = nil) {
        self.branchName = branchName
        self.commitMessage = commitMessage
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestBody = pullRequestBody
    }
}

public struct GitDeliveryResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let plan: GitDeliveryPlan
    public let phases: [GitDeliveryPhase]
    public let pullRequestURL: String?

    public init(ok: Bool, plan: GitDeliveryPlan, phases: [GitDeliveryPhase], pullRequestURL: String?) {
        self.ok = ok
        self.plan = plan
        self.phases = phases
        self.pullRequestURL = pullRequestURL
    }
}

/// Classification of a single diff line for colorization. Extracted from
/// the SwiftUI view so the `+++`/`---` vs `+`/`-` guard is unit-testable
/// without instantiating a view (QA-007).
public enum DiffLineKind: String, Sendable, Equatable {
    case add, del, hunk, header, context

    public static func classify(_ line: some StringProtocol) -> DiffLineKind {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .add }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .del }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") { return .header }
        return .context
    }
}

/// Lightweight git-diff helpers. Spawns `git` directly so we never link
/// libgit. Used by the changed-files summary and the diff panel surface.
public enum GitDiff {

    public typealias FileEntry = GitFileEntry
    public typealias Summary = GitSummary

    /// `nil` when a git probe timed out: its partial output would read as a
    /// clean tree (or "not a repo"), so callers keep what they showed before
    /// or report the failure instead.
    public static func summary(in cwd: String) -> GitSummary? {
        guard let repo = isGitProbe(cwd) else { return nil }
        guard repo else {
            return GitSummary(isGitRepo: false, branch: nil, dirty: false, files: [], totalAdditions: 0, totalDeletions: 0)
        }
        var probes: [ProcessResult] = []
        for args in [
            ["rev-parse", "--abbrev-ref", "HEAD"],
            // Numstat over uncommitted changes (staged + unstaged combined).
            ["diff", "--numstat", "HEAD"],
            ["diff", "--name-status", "HEAD"],
            ["ls-files", "--others", "--exclude-standard"],
        ] {
            let r = run(args, cwd: cwd)
            // The rest would likely stall the same way; one deadline is enough.
            if r.timedOut { return nil }
            probes.append(r)
        }
        let branch = probes[0].stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let numstat = probes[1].stdout
        let nameStatus = probes[2].stdout
        let untracked = probes[3].stdout

        var statusMap: [String: GitFileStatus] = [:]
        var renameOldPath: [String: String] = [:]
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard let code = parts.first else { continue }
            if code.hasPrefix("R") {
                if parts.count >= 3 {
                    let old = parts[1]
                    let new = parts[2]
                    statusMap[new] = .renamed
                    renameOldPath[new] = old
                }
            } else if code.hasPrefix("C") {
                if parts.count >= 3 {
                    let new = parts[2]
                    statusMap[new] = .copied
                    renameOldPath[new] = parts[1]
                }
            } else if let single = code.first {
                let path = parts.count >= 2 ? parts[1] : ""
                if path.isEmpty { continue }
                switch single {
                case "A": statusMap[path] = .added
                case "M": statusMap[path] = .modified
                case "D": statusMap[path] = .deleted
                default: statusMap[path] = .unknown
                }
            }
        }

        var files: [GitFileEntry] = []
        var totalA = 0, totalD = 0
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3 else { continue }
            let isBinary = parts[0] == "-"
            let adds = isBinary ? 0 : Int(parts[0]) ?? 0
            let dels = isBinary ? 0 : Int(parts[1]) ?? 0
            let path = parts[2]
            totalA += adds; totalD += dels
            let st = statusMap[path] ?? .modified
            files.append(GitFileEntry(
                path: path,
                oldPath: renameOldPath[path],
                status: st,
                additions: adds,
                deletions: dels,
                binary: isBinary
            ))
        }
        for line in untracked.split(separator: "\n") {
            let p = String(line)
            guard !p.isEmpty else { continue }
            files.append(GitFileEntry(path: p, oldPath: nil, status: .untracked, additions: 0, deletions: 0, binary: false))
        }
        let dirty = !files.isEmpty
        return GitSummary(
            isGitRepo: true,
            branch: branch.isEmpty ? nil : branch,
            dirty: dirty,
            files: files,
            totalAdditions: totalA,
            totalDeletions: totalD
        )
    }

    public static func diff(in cwd: String, path: String?, ignoreWhitespace: Bool = false) -> String {
        // A timed-out probe is unknown, not "not a repo": run the diff, which
        // carries its own timeout notice.
        guard isGitProbe(cwd) != false else { return "" }
        var args = ["diff", "HEAD", "--no-color"]
        if ignoreWhitespace { args.append("-w") }
        if let path { args.append("--"); args.append(path) }
        return decoratedStdout(run(args, cwd: cwd))
    }

    /// Runs `git diff HEAD --no-color -- <paths>` in bounded batches and returns a
    /// dictionary keyed by the path of each file that has changes. Files
    /// absent from the output had no diff (same as calling `diff(in:path:)`
    /// and getting `""`). No per-file subprocesses.
    ///
    /// Renames: git uses `diff --git a/<old> b/<new>` in the header; the key
    /// in the returned dictionary is the `b/` (new / current) path, matching
    /// what callers track in `AgentTurnCheckpointFile.path`.
    ///
    /// Binary files appear in the output (`Binary files a/f and b/f differ`)
    /// and are preserved verbatim in the returned slice.
    public static func diffAll(in cwd: String, paths: [String]) -> [String: String] {
        guard isGitProbe(cwd) != false, !paths.isEmpty else { return [:] }
        // Foundation raises an NSException (not a Swift Error) above 4,096
        // arguments. Leave room for git and its flags in every invocation.
        let batchSize = 1_024
        var byPath: [String: String] = [:]
        for start in stride(from: 0, to: paths.count, by: batchSize) {
            let batch = Array(paths[start..<min(start + batchSize, paths.count)])
            let args = ["diff", "HEAD", "--no-color", "--"] + batch
            let result = run(args, cwd: cwd)
            byPath.merge(Self.splitCombinedDiff(decoratedStdout(result))) { _, new in new }
            // Files the killed diff never reached must not read as "no diff".
            if result.timedOut {
                for path in paths[start...] where byPath[path] == nil { byPath[path] = timeoutNotice }
                break
            }
        }
        return byPath
    }

    /// Splits the stdout of a `git diff` invocation that covers multiple files
    /// into a per-file dictionary. Each key is the `b/<path>` side of the
    /// `diff --git` header (i.e. the current/new path). The value is the full
    /// diff block for that file, including its opening `diff --git` line.
    ///
    /// Pure string parsing — no I/O. Exposed as `internal` so the test target
    /// (same module via `@testable import`) can exercise it directly with a
    /// synthetic diff blob without spawning git.
    static func splitCombinedDiff(_ combined: String) -> [String: String] {
        guard !combined.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var currentPath: String? = nil
        var currentLines: [String] = []

        func flush() {
            guard let path = currentPath, !currentLines.isEmpty else { return }
            result[path] = currentLines.joined(separator: "\n") + "\n"
        }

        // Iterate line-by-line; `diff --git a/... b/...` marks a new file block.
        // Use indices to avoid copying every line into a String.
        var remaining = combined[...]
        while !remaining.isEmpty {
            let lineEnd = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let line = String(remaining[..<lineEnd])
            remaining = lineEnd < remaining.endIndex
                ? remaining[remaining.index(after: lineEnd)...]
                : remaining[remaining.endIndex...]

            if line.hasPrefix("diff --git ") {
                flush()
                currentLines = [line]
                // Extract the `b/<path>` component from `diff --git a/X b/Y`.
                // The `b/` prefix length is 2. Handle spaces in paths: the
                // split point is the last ` b/` occurrence after ` a/`.
                if let bRange = line.range(of: " b/", options: .backwards) {
                    let bPath = String(line[line.index(bRange.lowerBound, offsetBy: 3)...])
                    currentPath = bPath.isEmpty ? nil : bPath
                } else {
                    currentPath = nil
                }
            } else {
                if currentPath != nil {
                    currentLines.append(line)
                }
            }
        }
        flush()
        return result
    }

    /// Synthesizes a unified-diff–style all-addition patch for an untracked
    /// file given its raw text content. No git I/O — pure and unit-testable.
    ///
    /// Returns `""` for binary content (contains a NUL byte) or files that
    /// exceed `maxLines` (default 10 000) so the caller can show the same
    /// "binary" / truncation treatment as the tracked-file path.
    ///
    /// Output shape matches what `git diff --no-index /dev/null <path>`
    /// produces so `DiffLineKind.classify` colorizes it correctly:
    /// ```
    /// diff --git a/<path> b/<path>
    /// --- /dev/null
    /// +++ b/<path>
    /// @@ -0,0 +1,N @@
    /// +<line1>
    /// +<line2>
    /// …
    /// ```
    public static func synthesizeUntrackedDiff(content: String, path: String, maxLines: Int = 10_000) -> String {
        // Binary guard: a NUL byte anywhere means we can't render as text.
        guard !content.contains("\0") else { return "" }
        let lines = content.components(separatedBy: "\n")
        // Drop a trailing empty element that `components(separatedBy:)` adds
        // for content that ends with a newline, so line-count matches reality.
        let contentLines: [String]
        if lines.last == "" {
            contentLines = Array(lines.dropLast())
        } else {
            contentLines = lines
        }
        // Large-file guard: rendering many thousands of '+' lines in TextKit
        // is as expensive as for tracked files; apply the same cap philosophy.
        guard contentLines.count <= maxLines else { return "" }
        let n = contentLines.count
        var out = ""
        out += "diff --git a/\(path) b/\(path)\n"
        out += "--- /dev/null\n"
        out += "+++ b/\(path)\n"
        out += "@@ -0,0 +1,\(n) @@\n"
        for line in contentLines {
            out += "+\(line)\n"
        }
        return out
    }

    /// Matches `FilePreviewSurface.maxTextPreviewBytes` (512 KiB). Untracked
    /// synthesis must not load more than the preview surface would.
    public static let untrackedDiffPreviewByteCap = 512 * 1024

    /// FileHandle prefix read. Never materializes bytes past `maxBytes`.
    ///
    /// WHY: untracked-diff synthesis and checkpoint snapshots used
    /// `Data(contentsOf:)` on the whole file, so a 10–20 MiB blob became a
    /// peak Data allocation even when the caller only needed a bounded prefix.
    public static func readFilePrefix(at url: URL, maxBytes: Int) -> Data? {
        let limit = max(0, maxBytes)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var out = Data()
        if limit == 0 { return out }
        out.reserveCapacity(min(limit, 64 * 1024))
        do {
            while out.count < limit {
                let chunk = try handle.read(upToCount: limit - out.count) ?? Data()
                if chunk.isEmpty { break }
                out.append(chunk)
            }
            return out
        } catch {
            return nil
        }
    }

    // MARK: branch / commit / history

    public static func branches(in cwd: String) -> GitBranches {
        guard isGit(cwd) else { return GitBranches(current: nil, locals: []) }
        let head = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = (head.isEmpty || head == "HEAD") ? nil : head
        let listed = run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: cwd).stdout
        let locals = nonEmptyLines(listed)
        return GitBranches(current: current, locals: locals)
    }

    public static func checkout(in cwd: String, branch: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", branch], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    /// Stash the working tree (incl. untracked) then checkout `branch`.
    /// Used by the dirty-checkout guard so users with uncommitted work
    /// can switch branches without losing changes (UX-004).
    public static func stashAndCheckout(in cwd: String, branch: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let stash = run(["stash", "push", "--include-untracked", "-m", "remote-code: switch to \(branch)"], cwd: cwd)
        guard stash.exit == 0 else { return GitActionResult(ok: false, message: actionMessage(stash)) }
        let r = run(["checkout", branch], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func restorePathToHead(in cwd: String, path: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", "HEAD", "--", path], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func createBranch(in cwd: String, name: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", "-b", name], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func createWorktree(in cwd: String, path: String, branch: String, baseBranch: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["worktree", "add", "-b", branch, path, baseBranch], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func pullRequestRef(from urlString: String) -> GitPullRequestRef? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let numberString: String = {
            if let pullIndex = parts.firstIndex(of: "pull"), parts.indices.contains(pullIndex + 1) {
                return parts[pullIndex + 1]
            }
            if let markerIndex = parts.firstIndex(of: "-"),
               parts.indices.contains(markerIndex + 2),
               parts[markerIndex + 1] == "merge_requests" {
                return parts[markerIndex + 2]
            }
            return nil
        }(), let number = Int(numberString), number > 0 else { return nil }

        let repoParts: [String]
        let remoteRef: String
        if let pullIndex = parts.firstIndex(of: "pull"), pullIndex >= 2 {
            repoParts = Array(parts[..<pullIndex])
            remoteRef = "refs/pull/\(number)/head"
        } else if let markerIndex = parts.firstIndex(of: "-"), markerIndex >= 2 {
            repoParts = Array(parts[..<markerIndex])
            remoteRef = "refs/merge-requests/\(number)/head"
        } else {
            return nil
        }
        let repoPath = repoParts.joined(separator: "/")
        guard !repoPath.isEmpty else { return nil }
        return GitPullRequestRef(host: host, repositoryPath: repoPath, number: number, remoteRef: remoteRef, webURL: urlString)
    }

    public static func preparePullRequestWorktree(in cwd: String, urlString: String, worktreePath requestedPath: String? = nil) -> GitPullRequestPreparation {
        guard isGit(cwd) else {
            let ref = pullRequestRef(from: urlString) ?? GitPullRequestRef(host: "", repositoryPath: "", number: 0, remoteRef: "", webURL: urlString)
            return GitPullRequestPreparation(ref: ref, worktreePath: requestedPath ?? "", branch: "", result: GitActionResult(ok: false, message: "Not a git repository."))
        }
        guard let ref = pullRequestRef(from: urlString) else {
            let fallback = GitPullRequestRef(host: "", repositoryPath: "", number: 0, remoteRef: "", webURL: urlString)
            return GitPullRequestPreparation(ref: fallback, worktreePath: requestedPath ?? "", branch: "", result: GitActionResult(ok: false, message: "Unsupported pull request URL."))
        }
        let trackingRef: String
        let fetchedRemote: String?
        let fetch = fetchPullRequestRef(ref, cwd: cwd)
        guard fetch.result.exit == 0 else {
            return GitPullRequestPreparation(ref: ref, worktreePath: requestedPath ?? "", branch: "", result: GitActionResult(ok: false, message: actionMessage(fetch.result)))
        }
        trackingRef = fetch.trackingRef
        fetchedRemote = fetch.remoteName
        let branch = "rc-pr/\(safeRefComponent(ref.host))/\(safeRefComponent(ref.repositoryPath))-\(ref.number)"
        let path: String
        if let requestedPath, !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path = requestedPath
        } else {
            let root = URL(fileURLWithPath: cwd).standardizedFileURL
            let parent = root.deletingLastPathComponent()
            let repoName = root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent
            path = parent.appendingPathComponent("\(repoName)-pr-worktrees").appendingPathComponent("pr-\(ref.number)").path
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let add = run(["worktree", "add", "-B", branch, path, trackingRef], cwd: cwd)
        if add.exit == 0, let fetchedRemote {
            _ = run(["branch", "--set-upstream-to=\(fetchedRemote)/pr/\(ref.number)", branch], cwd: path)
        }
        return GitPullRequestPreparation(ref: ref, worktreePath: path, branch: branch, result: GitActionResult(ok: add.exit == 0, message: actionMessage(add)))
    }

    /// Removes exactly one worktree that Git still registers for `cwd`.
    /// The exact registration check prevents cleanup of an unrelated directory
    /// when PR preparation succeeds but the subsequent thread commit fails.
    public static func removeRegisteredWorktree(in cwd: String, worktreePath: String) -> GitActionResult {
        guard isGit(cwd) else {
            return GitActionResult(ok: false, message: "Not a git repository.")
        }
        let root = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let target = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        guard !target.isEmpty, target != root else {
            return GitActionResult(ok: false, message: "Refusing to remove the primary worktree.")
        }
        let registered = run(["worktree", "list", "--porcelain"], cwd: cwd)
        guard registered.exit == 0 else {
            return GitActionResult(ok: false, message: actionMessage(registered))
        }
        let registeredPaths = Set(registered.stdout.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("worktree ") else { return nil }
            return URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
                .standardizedFileURL.path
        })
        guard registeredPaths.contains(target) else {
            return GitActionResult(ok: false, message: "Worktree is not registered for this repository.")
        }
        let removal = run(["worktree", "remove", "--force", "--", target], cwd: cwd)
        return GitActionResult(ok: removal.exit == 0, message: actionMessage(removal))
    }

    /// Stages every change (`git add -A`) then commits with `message`.
    public static func commit(in cwd: String, message: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let add = run(["add", "-A"], cwd: cwd)
        guard add.exit == 0 else { return GitActionResult(ok: false, message: actionMessage(add)) }
        let r = run(["commit", "-m", message], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    /// Stages only the specified `paths` (`git add <paths…>`) then commits.
    /// Use this for per-file commit: the caller is responsible for passing a
    /// non-empty, validated list (see `StagingHelper.pathArgs`).
    public static func commitPaths(in cwd: String, message: String, paths: [String]) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        guard !paths.isEmpty else { return GitActionResult(ok: false, message: "No paths specified.") }
        let add = run(["add", "--"] + paths, cwd: cwd)
        guard add.exit == 0 else { return GitActionResult(ok: false, message: actionMessage(add)) }
        let r = run(["commit", "-m", message], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func log(in cwd: String, limit: Int = 100) -> [GitCommit] {
        guard isGit(cwd) else { return [] }
        let fmt = "%H%x1f%h%x1f%an%x1f%ad%x1f%s"
        let out = run(["log", "-n", String(limit), "--date=short", "--pretty=format:\(fmt)"], cwd: cwd).stdout
        var commits: [GitCommit] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }
            commits.append(GitCommit(hash: f[0], shortHash: f[1], author: f[2], date: f[3], subject: f[4]))
        }
        return commits
    }

    /// remotecode.io GitQuickControl parity — a sensible fallback commit
    /// subject derived from the working-tree summary.
    public static func suggestCommitMessage(_ s: GitSummary) -> String {
        guard !s.files.isEmpty else { return "" }
        let stat = "+\(s.totalAdditions) −\(s.totalDeletions)"
        if s.files.count == 1 { return "Update \(s.files[0].path) (\(stat))" }
        return "Update \(s.files.count) files (\(stat))"
    }

    public static func deliveryPlan(in cwd: String) -> GitDeliveryPlan {
        deliveryPlan(in: cwd, copy: nil)
    }

    public static func deliveryPlan(in cwd: String, copy: GitDeliveryCopy?) -> GitDeliveryPlan {
        let summary = self.summary(in: cwd)
        guard let summary, summary.isGitRepo else {
            return GitDeliveryPlan(
                branchName: "",
                commitMessage: "",
                pullRequestTitle: "",
                pullRequestBody: "",
                pullRequestURL: nil,
                phases: [GitDeliveryPhase(name: "inspect", status: .blocked, detail: summary == nil ? summaryTimedOutMessage : "Not a git repository.")]
            )
        }
        let fallbackCommitMessage = suggestCommitMessage(summary)
        let commitMessage = sanitizedCommitMessage(copy?.commitMessage) ?? fallbackCommitMessage
        let branchName = sanitizedBranchName(copy?.branchName) ?? deliveryBranchName(summary: summary)
        let title = sanitizedTitle(copy?.pullRequestTitle) ?? (commitMessage.isEmpty ? "Update workspace" : commitMessage)
        let changed = summary.files.map { "- \($0.path) (\($0.status.rawValue))" }.joined(separator: "\n")
        let fallbackBody = """
        ## Summary
        \(summary.files.isEmpty ? "- No working tree changes detected." : changed)

        ## Stats
        +\(summary.totalAdditions) -\(summary.totalDeletions)
        """
        let body = sanitizedBody(copy?.pullRequestBody) ?? fallbackBody
        let prURL = pullRequestURL(in: cwd)
        return GitDeliveryPlan(
            branchName: branchName,
            commitMessage: commitMessage,
            pullRequestTitle: title,
            pullRequestBody: body,
            pullRequestURL: prURL,
            phases: [
                GitDeliveryPhase(name: "branch", status: branchName.isEmpty ? .blocked : .ready, detail: branchName.isEmpty ? "No branch name available." : branchName),
                GitDeliveryPhase(name: "commit", status: commitMessage.isEmpty ? .blocked : .ready, detail: commitMessage.isEmpty ? "No changes to commit." : commitMessage),
                GitDeliveryPhase(name: "push", status: summary.files.isEmpty ? .blocked : .ready, detail: summary.files.isEmpty ? "No changes to push." : "Push current branch after commit."),
                GitDeliveryPhase(name: "pull_request", status: prURL == nil ? .blocked : .ready, detail: prURL ?? "No origin remote or current branch for PR URL.")
            ]
        )
    }

    public static func deliver(in cwd: String) -> GitDeliveryResult {
        deliver(in: cwd, copy: nil, environment: nil)
    }

    public static func deliver(in cwd: String, environment: [String: String]?) -> GitDeliveryResult {
        deliver(in: cwd, copy: nil, environment: environment)
    }

    public static func deliver(in cwd: String, copy: GitDeliveryCopy?, environment: [String: String]?) -> GitDeliveryResult {
        let plan = deliveryPlan(in: cwd, copy: copy)
        let summary = self.summary(in: cwd)
        guard let summary, summary.isGitRepo else {
            return GitDeliveryResult(ok: false, plan: plan, phases: [
                GitDeliveryPhase(name: "inspect", status: .failed, detail: summary == nil ? summaryTimedOutMessage : "Not a git repository.")
            ], pullRequestURL: nil)
        }
        guard !summary.files.isEmpty else {
            return GitDeliveryResult(ok: false, plan: plan, phases: [
                GitDeliveryPhase(name: "commit", status: .blocked, detail: "No changes to commit.")
            ], pullRequestURL: plan.pullRequestURL)
        }

        var phases: [GitDeliveryPhase] = []
        let currentBranch = branches(in: cwd).current
        if currentBranch == plan.branchName {
            phases.append(GitDeliveryPhase(name: "branch", status: .skipped, detail: "Already on \(plan.branchName)."))
        } else {
            let branch = createBranch(in: cwd, name: plan.branchName)
            phases.append(GitDeliveryPhase(name: "branch", status: branch.ok ? .completed : .failed, detail: branch.message.isEmpty ? plan.branchName : branch.message))
            guard branch.ok else {
                return GitDeliveryResult(ok: false, plan: plan, phases: phases, pullRequestURL: nil)
            }
        }

        let committed = commit(in: cwd, message: plan.commitMessage)
        phases.append(GitDeliveryPhase(name: "commit", status: committed.ok ? .completed : .failed, detail: committed.message))
        guard committed.ok else {
            return GitDeliveryResult(ok: false, plan: plan, phases: phases, pullRequestURL: nil)
        }

        let pushed = push(in: cwd)
        phases.append(GitDeliveryPhase(name: "push", status: pushed.ok ? .completed : .failed, detail: pushed.message))
        guard pushed.ok else {
            return GitDeliveryResult(ok: false, plan: plan, phases: phases, pullRequestURL: nil)
        }

        let pullRequest = createPullRequest(in: cwd, plan: plan, environment: environment)
        phases.append(pullRequest.phase)
        return GitDeliveryResult(ok: true, plan: plan, phases: phases, pullRequestURL: pullRequest.url)
    }

    /// `git fetch --prune` - updates remote-tracking refs without touching the
    /// working tree. Safe to run at any time (no merge). Fails loud on auth errors.
    public static func fetch(in cwd: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["fetch", "--prune"], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    /// `git pull --ff-only` - fast-forward only, refuses to create a merge
    /// commit so the panel never silently mangles history. Callers should
    /// present the error copy from `humanizeError` on failure.
    public static func pull(in cwd: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["pull", "--ff-only"], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    /// `git push`; if there is no upstream, set one (`-u origin HEAD`).
    public static func push(in cwd: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["push"], cwd: cwd)
        if r.exit == 0 { return GitActionResult(ok: true, message: actionMessage(r)) }
        let combined = (r.stderr + r.stdout).lowercased()
        if combined.contains("no upstream") || combined.contains("set-upstream") || combined.contains("has no upstream") {
            let r2 = run(["push", "-u", "origin", "HEAD"], cwd: cwd)
            return GitActionResult(ok: r2.exit == 0, message: actionMessage(r2))
        }
        return GitActionResult(ok: false, message: actionMessage(r))
    }

    /// A web URL to open a pull/merge request for the current branch,
    /// derived from `origin`. nil if not a repo / no usable remote.
    public static func pullRequestURL(in cwd: String) -> String? {
        guard isGit(cwd) else { return nil }
        guard let context = pullRequestContext(in: cwd) else { return nil }
        return pullRequestURL(host: context.host, repositoryPath: context.repositoryPath, branch: context.branch)
    }

    /// QA-010: pure URL builder taking host/path/branch as inputs (no git
    /// I/O) so the host-parsing matrix (github vs gitlab) is table-testable
    /// without a real remote.
    public static func pullRequestURL(host: String, repositoryPath path: String, branch: String) -> String? {
        guard !host.isEmpty, !path.isEmpty, !branch.isEmpty else { return nil }
        if host.contains("gitlab") {
            return "https://\(host)/\(path)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(branch)"
        }
        // GitHub (and GitHub-compatible) compare page.
        return "https://\(host)/\(path)/compare/\(branch)?expand=1"
    }

    /// QA-010: pure host/path extractor for a remote URL (git@ and https
    /// forms, `.git` suffix), independent of a real repo — table-testable.
    public static func parseRemote(_ remote: String) -> (host: String, path: String)? {
        var host = "", path = ""
        if remote.hasPrefix("git@"), let colon = remote.firstIndex(of: ":") {
            host = String(remote[remote.index(remote.startIndex, offsetBy: 4)..<colon])
            path = String(remote[remote.index(after: colon)...])
        } else if let r = URL(string: remote), let h = r.host {
            host = h
            path = String(r.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host, path)
    }

    /// UX-015: translate common raw git stderr into actionable human copy.
    /// Returns the original text when no pattern matches so nothing is lost.
    public static func humanizeError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("would be overwritten by checkout") || lower.contains("please commit your changes or stash") {
            return "You have uncommitted changes that conflict with this switch. Commit or stash them first."
        }
        if lower.contains("no upstream") || lower.contains("has no upstream") || lower.contains("set-upstream") {
            return "This branch has no upstream. Push with “set upstream” to create one on the remote."
        }
        if lower.contains("does not appear to be a git repository") || lower.contains("could not read from remote repository") {
            return "Can’t reach the remote. Check that ‘origin’ is configured and you have network/auth access."
        }
        if lower.contains("authentication failed") || lower.contains("permission denied") || lower.contains("403") {
            return "Authentication failed. Check your git credentials or SSH key for this remote."
        }
        if lower.contains("nothing to commit") {
            return "Nothing to commit — the working tree is clean."
        }
        if lower.contains("’origin’ does not appear") || lower.contains("no such remote") {
            return "No ‘origin’ remote is configured for this repository."
        }
        // Pull-specific patterns:
        if lower.contains("conflict") || lower.contains("merge conflict") {
            return "Pull stopped due to conflicts. Resolve conflicts in the affected files, then commit."
        }
        if lower.contains("cannot fast-forward") || lower.contains("not possible to fast-forward") {
            return "Cannot fast-forward -- your branch has diverged from the remote. Merge or rebase manually."
        }
        if lower.contains("your local changes to the following files would be overwritten by merge") {
            return "Pull would overwrite your local changes. Commit or stash them first."
        }
        if lower.contains("already up to date") {
            return "Already up to date -- nothing to pull."
        }
        return raw
    }

    private struct PullRequestContext {
        let host: String
        let repositoryPath: String
        let branch: String
        let baseBranch: String
    }

    private struct PullRequestCreation {
        let phase: GitDeliveryPhase
        let url: String?
    }

    private static func pullRequestContext(in cwd: String) -> PullRequestContext? {
        guard isGit(cwd) else { return nil }
        let remote = run(["remote", "get-url", "origin"], cwd: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { return nil }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "HEAD" else { return nil }
        // Normalize git@host:owner/repo(.git) and https://host/owner/repo(.git)
        guard let (host, path) = parseRemote(remote) else { return nil }
        let originHead = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], cwd: cwd)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = originHead.hasPrefix("origin/") ? String(originHead.dropFirst("origin/".count)) : nil
        return PullRequestContext(host: host, repositoryPath: path, branch: branch, baseBranch: base?.isEmpty == false ? base! : "main")
    }

    private static func sanitizedCommitMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\u{0}") else { return nil }
        return String(trimmed.prefix(120))
    }

    private static func sanitizedTitle(_ value: String?) -> String? {
        sanitizedCommitMessage(value)
    }

    private static func sanitizedBody(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\u{0}") else { return nil }
        return String(trimmed.prefix(10_000))
    }

    // PERF: branch sanitization is a pure allowed-character set. CharacterSet
    // membership avoids recompiling ^[A-Za-z0-9._/-]+$ via range(of:options:
    // .regularExpression) on every delivery-plan branch candidate.
    private static let branchNameAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-"
    )

    private static func sanitizedBranchName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...100).contains(trimmed.count),
              !trimmed.hasPrefix("/"),
              !trimmed.hasSuffix("/"),
              !trimmed.contains(".."),
              !trimmed.contains("@{"),
              trimmed.unicodeScalars.allSatisfy({ branchNameAllowedCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func createPullRequest(in cwd: String, plan: GitDeliveryPlan, environment: [String: String]?) -> PullRequestCreation {
        guard let context = pullRequestContext(in: cwd), let fallbackURL = pullRequestURL(in: cwd) else {
            return PullRequestCreation(
                phase: GitDeliveryPhase(name: "pull_request", status: .blocked, detail: "No origin remote or current branch for PR URL."),
                url: nil
            )
        }
        if context.host.contains("github") {
            let auth = runCommand(["gh", "auth", "status"], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            guard auth.exit == 0 else {
                return PullRequestCreation(
                    phase: GitDeliveryPhase(name: "pull_request", status: .ready, detail: fallbackURL),
                    url: fallbackURL
                )
            }
            let created = runCommand([
                "gh", "pr", "create",
                "--title", plan.pullRequestTitle,
                "--body", plan.pullRequestBody,
                "--head", context.branch,
                "--base", context.baseBranch
            ], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            return pullRequestCreationResult(created, fallbackURL: fallbackURL)
        }
        if context.host.contains("gitlab") {
            let auth = runCommand(["glab", "auth", "status"], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            guard auth.exit == 0 else {
                return PullRequestCreation(
                    phase: GitDeliveryPhase(name: "pull_request", status: .ready, detail: fallbackURL),
                    url: fallbackURL
                )
            }
            let created = runCommand([
                "glab", "mr", "create",
                "--title", plan.pullRequestTitle,
                "--description", plan.pullRequestBody,
                "--source-branch", context.branch,
                "--target-branch", context.baseBranch
            ], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            return pullRequestCreationResult(created, fallbackURL: fallbackURL)
        }
        return PullRequestCreation(
            phase: GitDeliveryPhase(name: "pull_request", status: .ready, detail: fallbackURL),
            url: fallbackURL
        )
    }

    private static func pullRequestCreationResult(_ result: ProcessResult, fallbackURL: String) -> PullRequestCreation {
        guard result.exit == 0 else {
            return PullRequestCreation(
                phase: GitDeliveryPhase(name: "pull_request", status: .failed, detail: actionMessage(result)),
                url: fallbackURL
            )
        }
        let output = (result.stdout + "\n" + result.stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let url = output.first { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? fallbackURL
        return PullRequestCreation(
            phase: GitDeliveryPhase(name: "pull_request", status: .completed, detail: url),
            url: url
        )
    }

    private static func nonInteractiveEnvironment(_ environment: [String: String]?) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment ?? [:] {
            merged[key] = value
        }
        merged["GH_PROMPT_DISABLED"] = "1"
        merged["GLAB_PROMPT_DISABLED"] = "1"
        return merged
    }

    public static func commitDiff(in cwd: String, hash: String, ignoreWhitespace: Bool = false) -> String {
        guard isGit(cwd) else { return "" }
        var args = ["show", hash, "--no-color"]
        if ignoreWhitespace { args.append("-w") }
        return decoratedStdout(run(args, cwd: cwd))
    }

    // MARK: helpers

    /// Prefer stderr (where git writes failures); fall back to stdout
    /// (e.g. "nothing to commit") so errors are never surfaced empty.
    private static func actionMessage(_ r: ProcessResult) -> String {
        let e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // PERF: safeRefComponent edge-trims dashes for PR/delivery branch segments;
    // share one CharacterSet instead of allocating CharacterSet(charactersIn:)
    // per host/repo/path fragment.
    private static let refComponentEdgeTrimSet = CharacterSet(charactersIn: "-")

    private static func safeRefComponent(_ raw: String) -> String {
        raw.lowercased()
            .map { char in
                char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
            }
            .reduce(into: "") { partial, char in
                if char == "-", partial.last == "-" { return }
                partial.append(char)
            }
            .trimmingCharacters(in: refComponentEdgeTrimSet)
    }

    private static func deliveryBranchName(summary: GitSummary) -> String {
        let base: String
        if let first = summary.files.first?.path, !first.isEmpty {
            base = "agent/\(safeRefComponent(first.replacingOccurrences(of: ".", with: "-")))"
        } else {
            base = "agent/update"
        }
        return base.isEmpty ? "agent/update" : String(base.prefix(72))
    }

    private struct PullRequestFetch {
        let result: ProcessResult
        let trackingRef: String
        let remoteName: String?
    }

    private static func fetchPullRequestRef(_ ref: GitPullRequestRef, cwd: String) -> PullRequestFetch {
        var remotes = remoteNames(in: cwd)
        if remotes.contains("origin") {
            remotes.removeAll { $0 == "origin" }
            remotes.insert("origin", at: 0)
        }
        if let upstreamIndex = remotes.firstIndex(of: "upstream"), upstreamIndex > 1 {
            remotes.remove(at: upstreamIndex)
            remotes.insert("upstream", at: 1)
        }
        for remote in remotes {
            let trackingRef = "refs/remotes/\(remote)/pr/\(ref.number)"
            let result = run(["fetch", remote, "\(ref.remoteRef):\(trackingRef)"], cwd: cwd)
            if result.exit == 0 {
                return PullRequestFetch(result: result, trackingRef: trackingRef, remoteName: remote)
            }
        }
        let directURL = "https://\(ref.host)/\(ref.repositoryPath).git"
        let direct = run(["fetch", directURL, ref.remoteRef], cwd: cwd)
        return PullRequestFetch(result: direct, trackingRef: "FETCH_HEAD", remoteName: nil)
    }

    private static func remoteNames(in cwd: String) -> [String] {
        let listed = run(["remote"], cwd: cwd).stdout
        return nonEmptyLines(listed)
    }

    private static func nonEmptyLines(_ output: String) -> [String] {
        var lines: [String] = []
        for part in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { continue }
            lines.append(String(part))
        }
        return lines
    }

    public static func isGit(_ cwd: String) -> Bool {
        isGitProbe(cwd) == true
    }

    /// `nil` when the probe timed out.
    private static func isGitProbe(_ cwd: String) -> Bool? {
        let r = run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        if r.timedOut { return nil }
        return r.exit == 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Peak retained git stdout. Prefix keeps `summary` porcelain and the
    /// start of a patch usable; the fd is still drained to EOF.
    static let stdoutCaptureMaxBytes = 2 * 1024 * 1024
    /// Peak retained git stderr (diagnostics). Still drained to EOF.
    static let stderrCaptureMaxBytes = 1 * 1024 * 1024
    static let truncationNotice = "\n[RemoteCode] git output truncated; showing the captured prefix.\n"
    static let timeoutNotice = "\n[RemoteCode] git timed out and was stopped; this output is incomplete.\n"
    /// Shown where a changed-files list could not be refreshed.
    public static let summaryTimedOutMessage = "git timed out; the changed files were not refreshed."

    struct ProcessResult {
        let exit: Int32
        let stdout: String
        let stderr: String
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        /// Killed at its read-only deadline; stdout holds only what was read.
        let timedOut: Bool

        init(
            exit: Int32,
            stdout: String,
            stderr: String,
            stdoutTruncated: Bool = false,
            stderrTruncated: Bool = false,
            timedOut: Bool = false
        ) {
            self.exit = exit
            self.stdout = stdout
            self.stderr = stderr
            self.stdoutTruncated = stdoutTruncated
            self.stderrTruncated = stderrTruncated
            self.timedOut = timedOut
        }
    }

    /// Carries the background stderr read back to the caller (PERF-008).
    /// Access is serialized by the serial drain queue + `sync {}` barrier,
    /// so the unchecked-Sendable conformance is safe.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
        var truncated = false
    }

    /// Set by the timeout work item, read after the process has exited.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func run(_ args: [String], cwd: String) -> ProcessResult {
        runCommand(["git"] + args, cwd: cwd, environment: nil, timeout: timeout(forGitArguments: args))
    }

    /// Read-only probes the UI waits on (branch chip, summary, diff, history)
    /// are killed if still running after this long. Commands that change the
    /// repo or reach the network (commit hooks, push, fetch, pull, checkout)
    /// have no deadline: cutting them off could leave work half done.
    static let readOnlyCommandTimeout: TimeInterval = 60
    nonisolated(unsafe) static var readOnlyCommandTimeoutForTesting: TimeInterval?
    private static let readOnlySubcommands: Set<String> = [
        "rev-parse", "diff", "ls-files", "for-each-ref", "log", "show", "symbolic-ref",
    ]

    static func timeout(forGitArguments args: [String]) -> TimeInterval? {
        guard let subcommand = args.first, readOnlySubcommands.contains(subcommand) else { return nil }
        return readOnlyCommandTimeoutForTesting ?? readOnlyCommandTimeout
    }

    /// Decode a prefix-capped capture without turning a mid-character cut
    /// into `""`. Trim to a UTF-8 boundary; fall back to lossy decode.
    static func decodeCapturedUTF8(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var end = data.count
        while end > 0 {
            if let s = String(data: data.prefix(end), encoding: .utf8) {
                return s
            }
            end -= 1
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Prefix-retain at most `maxBytes` while draining the fd to EOF so a
    /// verbose child cannot fill the pipe or pin multi-MiB Data in-process.
    static func readCapped(_ handle: FileHandle, maxBytes: Int) -> (data: Data, truncated: Bool) {
        readCapped(handle, maxBytes: maxBytes, control: nil)
    }

    /// Same drain, but also stops once `control` reports that the root process
    /// exited and its short grace passed. EOF needs every copy of the write end
    /// closed, so a descendant that kept it would otherwise pin this thread
    /// forever after git itself exited. Leaves the handle open.
    static func readCapped(
        _ handle: FileHandle,
        maxBytes: Int,
        control: PipeDrainControl?
    ) -> (data: Data, truncated: Bool) {
        var acc = PipeAccumulator(maxBytes: maxBytes, retention: .prefix)
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return (acc.data, acc.truncated)
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                acc.append(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { break }
            // Stop only once the pipe is empty: bytes git wrote before it
            // exited are kept even if this thread ran late.
            if control?.shouldStop == true { break }
            // Data and EOF wake poll at once; the timeout only bounds how long
            // a stop request waits.
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pollDescriptor, 1, 100) < 0, errno != EINTR { break }
            if pollDescriptor.revents & Int16(POLLNVAL) != 0 { break }
        }
        return (acc.data, acc.truncated)
    }

    private static func decoratedStdout(_ r: ProcessResult) -> String {
        var stdout = r.stdout
        if r.stdoutTruncated { stdout += truncationNotice }
        if r.timedOut { stdout += timeoutNotice }
        return stdout
    }

    static func runCommand(
        _ args: [String],
        cwd: String,
        environment: [String: String]?,
        timeout: TimeInterval? = nil
    ) -> ProcessResult {
        let started = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        if let environment {
            p.environment = environment
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let drainControl = PipeDrainControl()
        p.terminationHandler = { _ in drainControl.finishRoot() }
        do { try p.run() } catch {
            let r = ProcessResult(exit: -1, stdout: "", stderr: String(describing: error))
            logCommand(args, result: r, elapsed: Date().timeIntervalSince(started))
            return r
        }
        // Drop the parent's write ends so EOF depends only on the child tree.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let timedOut = TimeoutFlag()
        let timeoutWork = timeout.map { seconds -> DispatchWorkItem in
            // Weak: a cancelled item stays queued until its deadline and must
            // not keep the Process and its pipe fds alive that long.
            let work = DispatchWorkItem { [weak p] in
                guard let p, p.isRunning else { return }
                timedOut.set()
                ProcessTerminator.terminateTreeImmediately(p)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
            return work
        }
        // PERF-008: drain stderr on a background thread while reading stdout
        // on the current one, so a child writing more than a pipe buffer
        // (large `git show`/`git diff`) can't block on a full pipe before
        // exit. Reading both only after `waitUntilExit()` on a single thread
        // is the classic Process deadlock. A reference box carries the
        // background result back without mutating a captured `var`.
        // Capture is prefix-capped (PipeAccumulator) so checkpoint enrich
        // cannot pin an unbounded patch; both fds drain to EOF, or until a
        // short grace after git exits if a descendant still holds them.
        let errBox = DataBox()
        let errReader = err.fileHandleForReading
        let q = DispatchQueue(label: "git.pipe.drain")
        q.async {
            let capped = readCapped(errReader, maxBytes: stderrCaptureMaxBytes, control: drainControl)
            errBox.data = capped.data
            errBox.truncated = capped.truncated
        }
        let outCapped = readCapped(out.fileHandleForReading, maxBytes: stdoutCaptureMaxBytes, control: drainControl)
        q.sync {}   // barrier: ensure stderr drain finished before reading box.
        p.waitUntilExit()
        timeoutWork?.cancel()
        var stderr = decodeCapturedUTF8(errBox.data)
        if timedOut.isSet, let timeout {
            if !stderr.isEmpty, !stderr.hasSuffix("\n") { stderr += "\n" }
            stderr += "\(args.first ?? "command") timed out after \(Int(timeout))s and was stopped."
        }
        let r = ProcessResult(
            exit: timedOut.isSet ? -1 : p.terminationStatus,
            stdout: decodeCapturedUTF8(outCapped.data),
            stderr: stderr,
            stdoutTruncated: outCapped.truncated,
            stderrTruncated: errBox.truncated,
            timedOut: timedOut.isSet
        )
        logCommand(args, result: r, elapsed: Date().timeIntervalSince(started))
        return r
    }

    /// QA-004: structured logging of git command, exit code, and elapsed
    /// time behind an env flag (`RC_GIT_DEBUG`) so debugging a "commit
    /// didn't work" report isn't blind. Off by default — zero cost in
    /// release runs that don't set the flag.
    private static let gitDebug = ProcessInfo.processInfo.environment["RC_GIT_DEBUG"] != nil
    private static func logCommand(_ args: [String], result: ProcessResult, elapsed: TimeInterval) {
        guard gitDebug else { return }
        let cmd = args.joined(separator: " ")
        let ms = Int(elapsed * 1000)
        if result.exit == 0 {
            FileHandle.standardError.write(Data("[git] ok exit=0 \(ms)ms  \(cmd)\n".utf8))
        } else {
            let msg = actionMessage(result).split(separator: "\n").first.map(String.init) ?? ""
            FileHandle.standardError.write(Data("[git] FAIL exit=\(result.exit) \(ms)ms  \(cmd)  — \(msg)\n".utf8))
        }
    }
}
