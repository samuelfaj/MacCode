import XCTest
@testable import AgentRuntime

final class GitDiffTests: XCTestCase {
    func test_diffAll_withMorePathsThanTheProcessArgumentLimit_preservesRequestedDiffs() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for path in ["first.txt", "last.txt", "excluded.txt"] {
            try "before\n".write(toFile: dir + "/" + path, atomically: true, encoding: .utf8)
        }
        run(["git", "-C", dir, "add", "."])
        run(["git", "-C", dir, "commit", "-q", "-m", "init"])
        for path in ["first.txt", "last.txt", "excluded.txt"] {
            try "after\n".write(toFile: dir + "/" + path, atomically: true, encoding: .utf8)
        }
        // The reported crash passed 22,490 arguments, including git and its flags.
        let paths = ["first.txt"] + (0..<22_483).map { "unchanged-\($0).txt" } + ["last.txt"]

        let diffs = GitDiff.diffAll(in: dir, paths: paths)

        XCTAssertEqual(Set(diffs.keys), ["first.txt", "last.txt"])
        for path in ["first.txt", "last.txt"] {
            XCTAssertEqual(diffs[path], GitDiff.diff(in: dir, path: path))
            XCTAssertTrue(diffs[path]?.contains("+after") == true)
        }
    }

    private func mkTmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "rc2-git-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        run(["git", "init", "-q", "-b", "main", dir])
        run(["git", "-C", dir, "config", "user.email", "t@t.t"])
        run(["git", "-C", dir, "config", "user.name", "test"])
        return dir
    }

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    private func shell(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func writeExecutable(_ path: String, _ body: String) throws {
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func test_summary_inNonGitDir_isNotRepo() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try XCTUnwrap(GitDiff.summary(in: dir))
        XCTAssertFalse(s.isGitRepo)
        XCTAssertTrue(s.files.isEmpty)
    }

    func test_summary_inGitDir_detectsAddedAndUntracked() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "a.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "init"])
        try "modified\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(GitDiff.summary(in: dir))
        XCTAssertTrue(s.isGitRepo)
        XCTAssertTrue(s.dirty)
        XCTAssertTrue(s.files.contains { $0.path == "a.txt" && $0.status == .modified })
        XCTAssertTrue(s.files.contains { $0.path == "b.txt" && $0.status == .untracked })
    }

    /// Seeds `dir` with one committed file so HEAD exists.
    private func seedCommit(_ dir: String) throws {
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "a.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "init"])
    }

    func test_branches_listsLocalAndCurrent() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "branch", "feature"])
        let b = GitDiff.branches(in: dir)
        XCTAssertEqual(b.current, "main")
        XCTAssertTrue(b.locals.contains("main"))
        XCTAssertTrue(b.locals.contains("feature"))
    }

    func test_checkout_switchesBranch() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "branch", "feature"])
        let r = GitDiff.checkout(in: dir, branch: "feature")
        XCTAssertTrue(r.ok, "checkout failed: \(r.message)")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "feature")
    }

    func test_createBranch_createsAndSwitches() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let r = GitDiff.createBranch(in: dir, name: "feature")
        XCTAssertTrue(r.ok, "createBranch failed: \(r.message)")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "feature")
    }

    func test_commit_stagesAllAndClearsTree() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        let r = GitDiff.commit(in: dir, message: "wip changes")
        XCTAssertTrue(r.ok, "commit failed: \(r.message)")
        XCTAssertFalse(try XCTUnwrap(GitDiff.summary(in: dir)).dirty,
                       "working tree must be clean after a stage-all commit")
        XCTAssertTrue(GitDiff.log(in: dir).contains { $0.subject == "wip changes" })
    }

    func test_commit_failsLoudlyWhenNothingToCommit() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let r = GitDiff.commit(in: dir, message: "noop")
        XCTAssertFalse(r.ok, "committing a clean tree must report failure, not silent success")
        XCTAssertFalse(r.message.isEmpty, "failure must carry a non-empty message")
    }

    func test_log_returnsRecentCommitsNewestFirst() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "second\n".write(toFile: dir + "/c.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "c.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "second commit"])
        let commits = GitDiff.log(in: dir, limit: 10)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "second commit", "log must be newest-first")
        XCTAssertEqual(commits[1].subject, "init")
        XCTAssertFalse(commits[0].shortHash.isEmpty)
        XCTAssertFalse(commits[0].hash.isEmpty)
    }

    // MARK: edge cases / fail-loud contract

    func test_branches_inNonGitDir_isEmptyAndNoCurrent() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let b = GitDiff.branches(in: dir)
        XCTAssertNil(b.current, "a non-repo has no current branch")
        XCTAssertTrue(b.locals.isEmpty)
    }

    func test_branches_detachedHead_currentIsNil() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "two\n".write(toFile: dir + "/d.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "d.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "second"])
        // Detach HEAD onto the first commit.
        let firstHash = GitDiff.log(in: dir).last!.hash
        run(["git", "-C", dir, "checkout", "-q", firstHash])
        XCTAssertNil(GitDiff.branches(in: dir).current,
                     "detached HEAD must report no current branch, not the literal 'HEAD'")
    }

    func test_checkout_nonexistentBranch_failsLoud() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let r = GitDiff.checkout(in: dir, branch: "does-not-exist")
        XCTAssertFalse(r.ok, "checking out a missing branch must fail")
        XCTAssertFalse(r.message.isEmpty, "failure must carry git's error text, not be silent")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "main",
                       "a failed checkout must not move HEAD")
    }

    func test_checkout_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.checkout(in: dir, branch: "main")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty)
    }

    func test_createBranch_duplicateName_failsLoud() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        XCTAssertTrue(GitDiff.createBranch(in: dir, name: "feature").ok)
        let again = GitDiff.createBranch(in: dir, name: "feature")
        XCTAssertFalse(again.ok, "creating an existing branch must fail")
        XCTAssertFalse(again.message.isEmpty)
    }

    func test_createBranch_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.createBranch(in: dir, name: "x")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty)
    }

    func test_commit_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.commit(in: dir, message: "x")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.message.isEmpty)
    }

    func test_commit_stagesDeletionsAndUntracked_thenTreeClean() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)                              // commits a.txt
        try FileManager.default.removeItem(atPath: dir + "/a.txt")  // deletion
        try "fresh\n".write(toFile: dir + "/e.txt", atomically: true, encoding: .utf8) // untracked
        let r = GitDiff.commit(in: dir, message: "remove a, add e")
        XCTAssertTrue(r.ok, "stage-all (git add -A) must include deletions + untracked: \(r.message)")
        let s = try XCTUnwrap(GitDiff.summary(in: dir))
        XCTAssertFalse(s.dirty, "tree must be clean after committing every change class")
        XCTAssertFalse(s.files.contains { $0.path == "a.txt" }, "deleted file must be gone")
    }

    func test_commit_preservesMultiWordMessageInLog() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        try "x\n".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        let msg = "fix: handle spaces and : colons in subject"
        XCTAssertTrue(GitDiff.commit(in: dir, message: msg).ok)
        XCTAssertEqual(GitDiff.log(in: dir).first?.subject, msg,
                       "the commit subject must round-trip verbatim through the %s log format")
    }

    func test_log_respectsLimit() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        for i in 0..<4 {
            try "\(i)\n".write(toFile: dir + "/n\(i).txt", atomically: true, encoding: .utf8)
            run(["git", "-C", dir, "add", "."])
            run(["git", "-C", dir, "commit", "-q", "-m", "c\(i)"])
        }
        XCTAssertEqual(GitDiff.log(in: dir, limit: 2).count, 2,
                       "limit must cap how many commits the panel pulls")
        XCTAssertEqual(GitDiff.log(in: dir, limit: 100).count, 5)
    }

    func test_log_inNonGitDir_isEmpty() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(GitDiff.log(in: dir).isEmpty)
    }

    func test_log_emptyRepoWithNoCommits_isEmpty() throws {
        let dir = try mkTmpRepo()      // initialized but no commits yet
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(GitDiff.log(in: dir).isEmpty,
                      "a repo with no commits must yield an empty history, not a crash")
    }

    func test_commitDiff_containsChangedPath_andEmptyForNonGit() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        let hash = GitDiff.log(in: dir).first!.hash
        let d = GitDiff.commitDiff(in: dir, hash: hash)
        XCTAssertTrue(d.contains("a.txt"), "git show output must reference the committed file")
        let nonGit = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: nonGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: nonGit) }
        XCTAssertEqual(GitDiff.commitDiff(in: nonGit, hash: hash), "")
    }

    func test_commitDiff_invalidHash_isEmpty() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        XCTAssertEqual(GitDiff.commitDiff(in: dir, hash: "deadbeefdeadbeef"), "",
                       "an unknown revision must yield empty output, not stale/garbage text")
    }

    // MARK: D4 — suggested commit message

    func test_suggestCommitMessage_singleManyAndEmpty() {
        let one = GitSummary(isGitRepo: true, branch: "m", dirty: true,
            files: [GitFileEntry(path: "a.txt", oldPath: nil, status: .modified, additions: 2, deletions: 1, binary: false)],
            totalAdditions: 2, totalDeletions: 1)
        XCTAssertEqual(GitDiff.suggestCommitMessage(one), "Update a.txt (+2 −1)")
        let many = GitSummary(isGitRepo: true, branch: "m", dirty: true,
            files: (0..<3).map { GitFileEntry(path: "f\($0)", oldPath: nil, status: .modified, additions: 1, deletions: 0, binary: false) },
            totalAdditions: 3, totalDeletions: 0)
        XCTAssertEqual(GitDiff.suggestCommitMessage(many), "Update 3 files (+3 −0)")
        let clean = GitSummary(isGitRepo: true, branch: nil, dirty: false, files: [], totalAdditions: 0, totalDeletions: 0)
        XCTAssertEqual(GitDiff.suggestCommitMessage(clean), "", "a clean tree suggests no message")
    }

    func test_deliveryPlanBuildsStructuredBranchCommitPRTextAndPhases() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "checkout", "-qb", "feature/delivery"])
        run(["git", "-C", dir, "remote", "add", "origin", "git@github.com:acme/widget.git"])
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)

        let plan = GitDiff.deliveryPlan(in: dir)

        XCTAssertEqual(plan.branchName, "agent/a-txt")
        XCTAssertEqual(plan.commitMessage, "Update a.txt (+1 −1)")
        XCTAssertEqual(plan.pullRequestTitle, plan.commitMessage)
        XCTAssertTrue(plan.pullRequestBody.contains("- a.txt (modified)"))
        XCTAssertEqual(plan.pullRequestURL, "https://github.com/acme/widget/compare/feature/delivery?expand=1")
        XCTAssertEqual(plan.phases.map(\.name), ["branch", "commit", "push", "pull_request"],
                       "agent git delivery must expose explicit phase status instead of opaque commit/push side effects")
        XCTAssertEqual(plan.phases.map(\.status), [.ready, .ready, .ready, .ready])
    }

    func test_deliveryPlanUsesSafeProviderGeneratedCopyAndRejectsUnsafeBranch() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "checkout", "-qb", "feature/delivery"])
        run(["git", "-C", dir, "remote", "add", "origin", "git@github.com:acme/widget.git"])
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)

        let plan = GitDiff.deliveryPlan(in: dir, copy: GitDeliveryCopy(
            branchName: "../unsafe",
            commitMessage: "Tighten agent lifecycle handling",
            pullRequestTitle: "Agent lifecycle hardening",
            pullRequestBody: "Provider-generated body with test notes."
        ))

        XCTAssertEqual(plan.branchName, "agent/a-txt",
                       "unsafe provider-generated branch names must fall back to deterministic local branch text")
        XCTAssertEqual(plan.commitMessage, "Tighten agent lifecycle handling",
                       "safe provider-generated commit copy should replace deterministic fallback text")
        XCTAssertEqual(plan.pullRequestTitle, "Agent lifecycle hardening")
        XCTAssertEqual(plan.pullRequestBody, "Provider-generated body with test notes.")
    }

    func test_deliverRunsBranchCommitPushWithPhaseStatus() throws {
        let remote = NSTemporaryDirectory() + "rc2-deliver-bare-" + UUID().uuidString
        run(["git", "init", "-q", "--bare", remote])
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: remote) }
        try seedCommit(dir)
        run(["git", "-C", dir, "remote", "add", "origin", remote])
        run(["git", "-C", dir, "push", "-q", "origin", "main"])
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)

        let result = GitDiff.deliver(in: dir)

        XCTAssertTrue(result.ok, "one-shot delivery must run branch -> commit -> push without hiding per-phase failures: \(result.phases)")
        XCTAssertEqual(result.phases.map(\.name), ["branch", "commit", "push", "pull_request"])
        XCTAssertEqual(result.phases.prefix(3).map(\.status), [.completed, .completed, .completed])
        XCTAssertEqual(GitDiff.branches(in: dir).current, "agent/a-txt")
        XCTAssertEqual(GitDiff.log(in: dir, limit: 1).first?.subject, "Update a.txt (+1 −1)")
    }

    func test_deliverCreatesGitHubPullRequestWhenAuthenticatedCliIsAvailable() throws {
        let remote = NSTemporaryDirectory() + "rc2-deliver-gh-bare-" + UUID().uuidString
        run(["git", "init", "-q", "--bare", remote])
        let dir = try mkTmpRepo()
        let bin = NSTemporaryDirectory() + "rc2-deliver-gh-bin-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: remote)
            try? FileManager.default.removeItem(atPath: bin)
        }
        try seedCommit(dir)
        run(["git", "-C", dir, "remote", "add", "origin", "git@github.com:acme/widget.git"])
        run(["git", "-C", dir, "remote", "set-url", "--push", "origin", remote])
        run(["git", "-C", dir, "push", "-q", "origin", "main"])
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let logPath = bin + "/gh.log"
        try writeExecutable(bin + "/gh", """
        #!/bin/sh
        echo "$@" >> "\(logPath)"
        if [ "$1" = "auth" ]; then exit 0; fi
        echo "https://github.com/acme/widget/pull/77"
        exit 0
        """)

        let result = GitDiff.deliver(in: dir, environment: ["PATH": "\(bin):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"])

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.pullRequestURL, "https://github.com/acme/widget/pull/77")
        XCTAssertEqual(result.phases.map(\.name), ["branch", "commit", "push", "pull_request"])
        XCTAssertEqual(result.phases.map(\.status), [.completed, .completed, .completed, .completed],
                       "authenticated GitHub CLI delivery must create the PR instead of returning only a compare URL")
        let ghLog = try String(contentsOfFile: logPath)
        XCTAssertTrue(ghLog.contains("auth status"))
        XCTAssertTrue(ghLog.contains("pr create"))
        XCTAssertTrue(ghLog.contains("--head agent/a-txt"))
        XCTAssertTrue(ghLog.contains("--base main"))
    }

    func test_deliverLeavesPullRequestReadyWhenCliAuthIsUnavailable() throws {
        let remote = NSTemporaryDirectory() + "rc2-deliver-noauth-bare-" + UUID().uuidString
        run(["git", "init", "-q", "--bare", remote])
        let dir = try mkTmpRepo()
        let bin = NSTemporaryDirectory() + "rc2-deliver-noauth-bin-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: remote)
            try? FileManager.default.removeItem(atPath: bin)
        }
        try seedCommit(dir)
        run(["git", "-C", dir, "remote", "add", "origin", "git@github.com:acme/widget.git"])
        run(["git", "-C", dir, "remote", "set-url", "--push", "origin", remote])
        run(["git", "-C", dir, "push", "-q", "origin", "main"])
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let logPath = bin + "/gh.log"
        try writeExecutable(bin + "/gh", """
        #!/bin/sh
        echo "$@" >> "\(logPath)"
        if [ "$1" = "auth" ]; then exit 1; fi
        exit 2
        """)

        let result = GitDiff.deliver(in: dir, environment: ["PATH": "\(bin):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"])

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.pullRequestURL, "https://github.com/acme/widget/compare/agent/a-txt?expand=1")
        XCTAssertEqual(result.phases.last?.status, .ready,
                       "without authenticated gh/glab context, delivery must avoid a blind remote mutation and return the create-PR URL")
        XCTAssertFalse((try String(contentsOfFile: logPath)).contains("pr create"))
    }

    // MARK: D2 — push / pull-request URL

    func test_push_setsUpstreamThenPushesAgain() throws {
        let remote = NSTemporaryDirectory() + "rc2-bare-" + UUID().uuidString
        run(["git", "init", "-q", "--bare", remote])
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: remote) }
        try seedCommit(dir)
        run(["git", "-C", dir, "remote", "add", "origin", remote])
        let first = GitDiff.push(in: dir)
        XCTAssertTrue(first.ok, "first push must set upstream and succeed: \(first.message)")
        try "more\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "commit", "-aqm", "second"])
        XCTAssertTrue(GitDiff.push(in: dir).ok, "subsequent push (upstream set) must also succeed")
    }

    func test_push_notGitRepo_failsLoud() {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = GitDiff.push(in: dir)
        XCTAssertFalse(r.ok); XCTAssertFalse(r.message.isEmpty)
    }

    func test_pullRequestURL_githubSSH_gitlabHTTPS_andNoRemote() throws {
        let dir = try mkTmpRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try seedCommit(dir)
        run(["git", "-C", dir, "checkout", "-qb", "feature/x"])
        XCTAssertNil(GitDiff.pullRequestURL(in: dir), "no origin → no PR URL")
        run(["git", "-C", dir, "remote", "add", "origin", "git@github.com:acme/widget.git"])
        XCTAssertEqual(GitDiff.pullRequestURL(in: dir),
                       "https://github.com/acme/widget/compare/feature/x?expand=1",
                       "git@github SSH remote must normalize to a GitHub compare URL")
        run(["git", "-C", dir, "remote", "set-url", "origin", "https://gitlab.com/acme/widget.git"])
        XCTAssertEqual(GitDiff.pullRequestURL(in: dir),
                       "https://gitlab.com/acme/widget/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature/x",
                       "GitLab remotes must use the MR-new URL shape")
    }

    func test_pullRequestRef_parsesGitHubAndGitLabUrls() throws {
        let github = try XCTUnwrap(GitDiff.pullRequestRef(from: "https://github.com/acme/widget/pull/42"))
        XCTAssertEqual(github.host, "github.com")
        XCTAssertEqual(github.repositoryPath, "acme/widget")
        XCTAssertEqual(github.number, 42)
        XCTAssertEqual(github.remoteRef, "refs/pull/42/head")

        let gitlab = try XCTUnwrap(GitDiff.pullRequestRef(from: "https://gitlab.com/group/sub/widget/-/merge_requests/9"))
        XCTAssertEqual(gitlab.host, "gitlab.com")
        XCTAssertEqual(gitlab.repositoryPath, "group/sub/widget")
        XCTAssertEqual(gitlab.number, 9)
        XCTAssertEqual(gitlab.remoteRef, "refs/merge-requests/9/head")
    }

    func test_preparePullRequestWorktree_fetchesPullRefIntoIsolatedWorktree() throws {
        let dir = try mkTmpRepo()
        let bare = NSTemporaryDirectory() + "rc2-pr-origin-" + UUID().uuidString + ".git"
        let worktreeRoot = dir + "-pr-worktrees"
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: bare)
            try? FileManager.default.removeItem(atPath: worktreeRoot)
        }
        try seedCommit(dir)
        run(["git", "init", "--bare", "-q", bare])
        run(["git", "-C", dir, "remote", "add", "origin", bare])
        run(["git", "-C", dir, "push", "-q", "origin", "main"])
        run(["git", "-C", dir, "checkout", "-qb", "feature/pr-7"])
        try "from pr\n".write(toFile: dir + "/pr.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "pr.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "pr"])
        run(["git", "-C", dir, "push", "-q", "origin", "HEAD:refs/pull/7/head"])
        run(["git", "-C", dir, "checkout", "-q", "main"])

        let prep = GitDiff.preparePullRequestWorktree(
            in: dir,
            urlString: "https://github.com/acme/widget/pull/7",
            worktreePath: worktreeRoot + "/pr-7"
        )

        XCTAssertTrue(prep.result.ok, prep.result.message)
        XCTAssertEqual(prep.branch, "rc-pr/github-com/acme-widget-7")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep.worktreePath + "/pr.txt"),
                      "PR preparation must checkout the PR head into an isolated worktree so Agent App work does not mutate the base checkout")
        XCTAssertEqual(GitDiff.branches(in: prep.worktreePath).current, prep.branch)
    }

    func test_removeRegisteredWorktree_removesOnlyExactTarget() throws {
        let dir = try mkTmpRepo()
        let first = dir + "-cleanup-first"
        let second = dir + "-cleanup-second"
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
            try? FileManager.default.removeItem(atPath: dir)
        }
        try seedCommit(dir)
        XCTAssertTrue(GitDiff.createWorktree(
            in: dir,
            path: first,
            branch: "cleanup-first",
            baseBranch: "main"
        ).ok)
        XCTAssertTrue(GitDiff.createWorktree(
            in: dir,
            path: second,
            branch: "cleanup-second",
            baseBranch: "main"
        ).ok)
        try "untracked hook residue\n".write(
            toFile: first + "/untracked.txt",
            atomically: true,
            encoding: .utf8
        )

        let result = GitDiff.removeRegisteredWorktree(in: dir, worktreePath: first)

        XCTAssertTrue(result.ok, result.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first),
                       "the just-created target must be force-cleaned even if a hook leaves untracked residue")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second),
                      "cleanup of a failed PR commit must not remove another registered worktree")
        XCTAssertFalse(GitDiff.removeRegisteredWorktree(in: dir, worktreePath: dir).ok,
                       "the cleanup API must never accept the primary checkout")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
    }

    // MARK: splitCombinedDiff -- per-file splitting of a combined git diff output
    //
    // WHY: captureFileDiffs collapses N per-file git subprocesses into one
    // `git diff HEAD -- <paths>` call and splits the combined stdout back into
    // per-file patches. The split MUST reproduce exactly the same patch text
    // that the old per-file `GitDiff.diff(in:path:)` calls returned. This test
    // verifies correctness of the pure parser against a synthetic multi-file blob
    // without spawning git, covering renames, binary-file markers, and the case
    // where a requested file is absent from the output (no changes / untracked).

    func test_splitCombinedDiff_multiFileBlob_returnsCorrectPerFileSegments() throws {
        // Synthetic `git diff HEAD --no-color` output covering three files:
        //   src/foo.swift  -- modified
        //   README.md      -- binary (git binary-file marker)
        //   src/bar.swift  -- renamed from src/baz.swift (rename, b/ path is bar.swift)
        let combined = """
        diff --git a/src/foo.swift b/src/foo.swift
        index abc1234..def5678 100644
        --- a/src/foo.swift
        +++ b/src/foo.swift
        @@ -1,3 +1,4 @@
         line1
        -line2
        +line2 modified
        +line3 new
         line4
        diff --git a/README.md b/README.md
        index 0000000..1111111 100644
        Binary files a/README.md and b/README.md differ
        diff --git a/src/baz.swift b/src/bar.swift
        similarity index 90%
        rename from src/baz.swift
        rename to src/bar.swift
        index aaa1111..bbb2222 100644
        --- a/src/baz.swift
        +++ b/src/bar.swift
        @@ -1 +1,2 @@
         same
        +added
        """

        let result = GitDiff.splitCombinedDiff(combined)

        // Three entries, keyed by b/ path.
        XCTAssertEqual(result.keys.sorted(), ["README.md", "src/bar.swift", "src/foo.swift"],
                       "splitCombinedDiff must key each block by the b/ (current/new) path so callers can look up by file.path")

        // foo.swift block starts with the diff --git header and contains all hunk lines.
        let fooBlock = try XCTUnwrap(result["src/foo.swift"])
        XCTAssertTrue(fooBlock.hasPrefix("diff --git a/src/foo.swift b/src/foo.swift\n"),
                      "each block must begin with its own diff --git header line, matching what per-file git diff produced")
        XCTAssertTrue(fooBlock.contains("+line2 modified"),
                      "hunk lines must be preserved verbatim inside the per-file block")
        XCTAssertTrue(fooBlock.contains("+line3 new"))

        // Binary file block must include the Binary files marker line.
        let readmeBlock = try XCTUnwrap(result["README.md"])
        XCTAssertTrue(readmeBlock.contains("Binary files a/README.md and b/README.md differ"),
                      "binary-file diff blocks must be preserved so the diff viewer can show the binary indicator")

        // Rename: key is the b/ path (bar.swift), block spans the full rename header + hunk.
        let barBlock = try XCTUnwrap(result["src/bar.swift"])
        XCTAssertTrue(barBlock.hasPrefix("diff --git a/src/baz.swift b/src/bar.swift\n"),
                      "renames must be keyed by the new (b/) path and include the full rename header")
        XCTAssertTrue(barBlock.contains("rename from src/baz.swift"))
        XCTAssertTrue(barBlock.contains("rename to src/bar.swift"))
        XCTAssertTrue(barBlock.contains("+added"))

        // A path not present in the output maps to nil (absent), not empty string --
        // caller treats nil / "" the same as "no diff" (untracked fallback message).
        XCTAssertNil(result["nonexistent.swift"],
                     "a path absent from the combined diff must be absent from the result so callers apply the untracked-file fallback, matching the old per-file diff behavior")
    }

    func test_splitCombinedDiff_emptyInput_returnsEmptyDictionary() {
        XCTAssertTrue(GitDiff.splitCombinedDiff("").isEmpty,
                      "empty git diff output (nothing to diff) must yield no entries, not a crash or a spurious empty-keyed entry")
    }

    func test_preparePullRequestWorktree_fallsBackToUpstreamRemoteAndTracksIt() throws {
        let dir = try mkTmpRepo()
        let forkBare = NSTemporaryDirectory() + "rc2-pr-fork-" + UUID().uuidString + ".git"
        let upstreamBare = NSTemporaryDirectory() + "rc2-pr-upstream-" + UUID().uuidString + ".git"
        let worktreeRoot = dir + "-pr-worktrees"
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: forkBare)
            try? FileManager.default.removeItem(atPath: upstreamBare)
            try? FileManager.default.removeItem(atPath: worktreeRoot)
        }
        try seedCommit(dir)
        run(["git", "init", "--bare", "-q", forkBare])
        run(["git", "init", "--bare", "-q", upstreamBare])
        run(["git", "-C", dir, "remote", "add", "origin", forkBare])
        run(["git", "-C", dir, "remote", "add", "upstream", upstreamBare])
        run(["git", "-C", dir, "push", "-q", "origin", "main"])
        run(["git", "-C", dir, "push", "-q", "upstream", "main"])
        run(["git", "-C", dir, "checkout", "-qb", "feature/pr-8"])
        try "from upstream pr\n".write(toFile: dir + "/upstream-pr.txt", atomically: true, encoding: .utf8)
        run(["git", "-C", dir, "add", "upstream-pr.txt"])
        run(["git", "-C", dir, "commit", "-q", "-m", "upstream pr"])
        run(["git", "-C", dir, "push", "-q", "upstream", "HEAD:refs/pull/8/head"])
        run(["git", "-C", dir, "checkout", "-q", "main"])

        let prep = GitDiff.preparePullRequestWorktree(
            in: dir,
            urlString: "https://github.com/acme/widget/pull/8",
            worktreePath: worktreeRoot + "/pr-8"
        )

        XCTAssertTrue(prep.result.ok, prep.result.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prep.worktreePath + "/upstream-pr.txt"),
                      "when origin is a fork without the PR ref, PR preparation must try upstream instead of failing before the Agent can inspect the PR")
        let upstream = shell(["git", "-C", prep.worktreePath, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        XCTAssertEqual(upstream.trimmingCharacters(in: .whitespacesAndNewlines), "upstream/pr/8",
                       "the isolated PR branch should track the remote PR ref it fetched from, preserving fork/upstream provenance")
    }

    // DIFF-UNCAPPED: FileHandle prefix must never materialize bytes past maxBytes.
    func test_readFilePrefix_doesNotMaterializeBytesPastMax() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-git-prefix-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x41, count: 256)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let prefix = try XCTUnwrap(GitDiff.readFilePrefix(at: url, maxBytes: 64))
        XCTAssertEqual(prefix.count, 64, "prefix read must stop at maxBytes")
        XCTAssertEqual(prefix, payload.prefix(64))
    }

    func test_readFilePrefix_shortFile_returnsEntireContents() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-git-prefix-short-\(UUID().uuidString).txt")
        let payload = Data("hello\n".utf8)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let prefix = try XCTUnwrap(GitDiff.readFilePrefix(at: url, maxBytes: 512 * 1024))
        XCTAssertEqual(prefix, payload)
    }

    func test_readFilePrefix_missingFile_returnsNil() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-git-prefix-missing-\(UUID().uuidString).bin")
        XCTAssertNil(
            GitDiff.readFilePrefix(at: url, maxBytes: 64),
            "open/read failure must return nil, not empty Data"
        )
    }

    func test_untrackedDiffPreviewByteCap_matchesFilePreview512KiB() {
        XCTAssertEqual(
            GitDiff.untrackedDiffPreviewByteCap, 512 * 1024,
            "untracked synthesis must share the 512 KiB FilePreviewSurface cap"
        )
    }
}
