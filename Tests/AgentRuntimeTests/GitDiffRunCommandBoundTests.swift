import XCTest
@testable import AgentRuntime

/// WHY: `GitDiff.runCommand` read stdout/stderr to EOF with no deadline. EOF
/// only arrives when every copy of the write end is closed, so a descendant
/// that kept the pipe (a hook's daemon, an fsmonitor, a terminal shell that
/// inherited it) pinned the calling thread and a `git.pipe.drain` thread
/// forever even though git itself had exited. The Agent App branch chip and
/// the diff summary never filled in.
final class GitDiffRunCommandBoundTests: XCTestCase {
    func test_runCommand_returnsOnceRootExits_evenWhenADescendantKeepsThePipe() {
        let started = Date()
        let result = GitDiff.runCommand(
            ["sh", "-c", "(/bin/sleep 4 &) ; echo hi ; echo warn >&2"],
            cwd: NSTemporaryDirectory(),
            environment: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        NSLog("[perf-proof] gitDiff runCommand descendant-holds-pipe elapsed_ms=%.0f", elapsed * 1_000)
        XCTAssertEqual(result.exit, 0)
        XCTAssertEqual(result.stdout, "hi\n", "output written before exit must still be captured")
        XCTAssertEqual(result.stderr, "warn\n")
        XCTAssertLessThan(elapsed, 2, "the reader must stop shortly after the root exits, not when the descendant does")
    }

    func test_runCommand_stopsAStuckReadOnlyProbeAtItsDeadline() {
        // A hung probe (fsmonitor, credential helper) must not pin the branch
        // chip's thread forever. `timedOut` lets callers report it as
        // unavailable rather than as empty output (tests below).
        let started = Date()
        let result = GitDiff.runCommand(
            ["sh", "-c", "/bin/sleep 30"],
            cwd: NSTemporaryDirectory(),
            environment: nil,
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.exit, -1)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.stderr.contains("timed out"), result.stderr)
        XCTAssertLessThan(elapsed, 3)
    }

    /// WHY: a probe killed at its deadline came back as exit -1 with whatever
    /// stdout it had read, and `summary` ignores exit codes, so a timed-out
    /// `diff --numstat` / `ls-files` read as a clean tree. The Agent header,
    /// the Diff panel and the persisted `.ready` checkpoint then said "no
    /// changes" while the edits were still on disk.
    func test_summary_whenAProbeTimesOut_isUnavailable_notACleanTree() throws {
        let repo = try makeDirtyRepoWithStalledFSMonitor()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        GitDiff.readOnlyCommandTimeoutForTesting = 0.5
        let started = Date()
        let stalled = GitDiff.summary(in: repo)
        let elapsed = Date().timeIntervalSince(started)
        GitDiff.readOnlyCommandTimeoutForTesting = nil
        XCTAssertNil(stalled, "a summary built from killed probes must be unavailable, not isGitRepo with files == []")
        XCTAssertLessThan(elapsed, 1.5, "the first killed probe ends the summary; the rest are not each waited out")

        // The same tree read without the stall: what the timed-out read hid.
        shell(["git", "-C", repo, "config", "--unset", "core.fsmonitor"])
        let fresh = try XCTUnwrap(GitDiff.summary(in: repo))
        XCTAssertEqual(Set(fresh.files.map(\.path)), ["a.txt", "new.txt"])
    }

    /// WHY: `diff` / `diffAll` only flagged truncation, so a diff killed
    /// partway (or before any output) came back looking complete, and a
    /// checkpoint stored it as the turn's patch.
    func test_diffAndDiffAll_whenTheyTimeOut_sayTheOutputIsIncomplete() throws {
        let repo = try makeDirtyRepoWithStalledFSMonitor()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        GitDiff.readOnlyCommandTimeoutForTesting = 0.5
        defer { GitDiff.readOnlyCommandTimeoutForTesting = nil }
        let patch = GitDiff.diff(in: repo, path: nil)
        let paths = ["a.txt"] + (0..<2_048).map { "missing-\($0).txt" }
        let started = Date()
        let perFile = GitDiff.diffAll(in: repo, paths: paths)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "stop after the first timed-out batch")
        XCTAssertTrue(patch.contains(GitDiff.timeoutNotice), patch)
        XCTAssertTrue(perFile["a.txt"]?.contains(GitDiff.timeoutNotice) == true, "\(perFile)")
        XCTAssertEqual(perFile[paths.last!], GitDiff.timeoutNotice, "unread batches must also be marked incomplete")
    }

    /// WHY: the drain checked its stop flag before every read, so a reader
    /// that ran more than the 0.25 s grace after git exited (a loaded
    /// machine, the separately queued stderr drain) dropped bytes git had
    /// already written: a short diff or a lost error, with exit 0 and no
    /// truncation flag.
    func test_readCapped_keepsBufferedBytes_whenTheReaderRunsAfterTheGrace() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("diff --git a/x b/x\n".utf8))
        // The write end stays open, as when a descendant holds it, so only
        // the stop can end this read.
        let control = PipeDrainControl()
        control.finishRoot()
        Thread.sleep(forTimeInterval: BoundedPipeDrain.defaultTimeout + 0.1)
        XCTAssertTrue(control.shouldStop)

        let result = GitDiff.readCapped(pipe.fileHandleForReading, maxBytes: 1024, control: control)

        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "diff --git a/x b/x\n")
        XCTAssertFalse(result.truncated)
    }

    func test_onlyReadOnlyGitCommandsGetADeadline() {
        // Killing a commit hook, push, fetch, pull or checkout midway could
        // leave work half done, so only probes the UI waits on are bounded.
        for args in [["rev-parse", "--is-inside-work-tree"], ["diff", "--numstat", "HEAD"], ["ls-files", "--others"], ["log", "-n", "1"]] {
            XCTAssertEqual(GitDiff.timeout(forGitArguments: args), GitDiff.readOnlyCommandTimeout, "\(args)")
        }
        for args in [["commit", "-m", "x"], ["push"], ["fetch", "--prune"], ["pull", "--ff-only"], ["checkout", "main"], ["add", "-A"], ["stash", "push"]] {
            XCTAssertNil(GitDiff.timeout(forGitArguments: args), "\(args)")
        }
    }

    /// A repo with a modified and an untracked file whose fsmonitor hook
    /// sleeps: `rev-parse` stays fast while `diff` and `ls-files` stall.
    private func makeDirtyRepoWithStalledFSMonitor() throws -> String {
        let repo = NSTemporaryDirectory() + "rc2-git-timeout-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        shell(["git", "init", "-q", "-b", "main", repo])
        shell(["git", "-C", repo, "config", "user.email", "t@t.t"])
        shell(["git", "-C", repo, "config", "user.name", "test"])
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        shell(["git", "-C", repo, "add", "a.txt"])
        shell(["git", "-C", repo, "commit", "-q", "-m", "init"])
        try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
        let hook = repo + "/.git/slow-fsmonitor.sh"
        try "#!/bin/sh\nsleep 30\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        shell(["git", "-C", repo, "config", "core.fsmonitor", hook])
        return repo
    }

    private func shell(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
