import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

final class FileLeaseServiceTests: XCTestCase {
    private let identity = RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: "main")

    private final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [FileLeaseNotice] = []
        func add(_ notice: FileLeaseNotice) { lock.withLock { items.append(notice) } }
        var all: [FileLeaseNotice] { lock.withLock { items } }
    }

    private func makeService(mode: FileLeaseMode, notices: Notices = Notices()) -> (FileLeaseService, Notices) {
        let identity = identity
        let service = FileLeaseService(
            mode: { mode },
            describe: { _ in ("Fix login", "@qa") },
            resolveIdentity: { _ in identity }
        )
        service.onNotice = { notices.add($0) }
        return (service, notices)
    }

    private func start(_ service: FileLeaseService) -> (run: AgentRunID, thread: AgentThreadID) {
        let run = AgentRunID(), thread = AgentThreadID()
        service.begin(runId: run, threadId: thread, cwd: "/work/app")
        return (run, thread)
    }

    func test_warnModeLetsTheSecondRunEditButTellsTheAgentWhoOwnsTheFile() async {
        let (service, notices) = makeService(mode: .warn)
        let first = start(service), second = start(service)
        let a = await service.checkEdit(runId: first.run, paths: ["/work/app/Sources/a.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(a, .allow)
        let b = await service.checkEdit(runId: second.run, paths: ["/work/app/Sources/a.swift"], cwd: nil, enforce: true)
        guard case .warn(let text) = b else { return XCTFail("expected a warning, got \(b)") }
        XCTAssertTrue(text.hasPrefix("`Sources/a.swift` is being edited by thread 'Fix login' (Bot @qa)"), text)
        XCTAssertTrue(text.hasSuffix("Edit another file, wait, or use a worktree."))
        XCTAssertEqual(notices.all.map(\.kind), [.conflictWarned])
        XCTAssertEqual(notices.all.first?.threadID, second.thread, "the user hears about it on the thread that hit the conflict")
        let holder = service.store.conflict(repoRoot: "/work/app", path: "Sources/a.swift", runID: second.run)
        XCTAssertEqual(holder?.runID, first.run, "a warned edit never steals the lease")
    }

    func test_blockModeRefusesTheEditAndLeavesTheLeaseWithItsOwner() async {
        let (service, notices) = makeService(mode: .block)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        let verdict = await service.checkEdit(runId: second.run, paths: ["/work/app/a.swift", "/work/app/free.swift"], cwd: nil, enforce: true)
        guard case .deny(let text) = verdict else { return XCTFail("expected a refusal, got \(verdict)") }
        XCTAssertTrue(text.contains("`a.swift`"))
        XCTAssertEqual(notices.all.map(\.kind), [.leaseDenied])
        XCTAssertNil(service.store.conflict(repoRoot: "/work/app", path: "free.swift", runID: first.run),
                     "a refused edit must not lease the other files of the same call")
    }

    func test_anEditAfterTheFactNeverDeniesEvenInBlockMode() async {
        let (service, notices) = makeService(mode: .block)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        let verdict = await service.checkEdit(runId: second.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: false)
        guard case .warn = verdict else { return XCTFail("Codex already edited; denying would be a lie, got \(verdict)") }
        XCTAssertEqual(notices.all.map(\.kind), [.conflictWarned])
    }

    func test_endingARunReleasesItsLeasesAndTheNextRunMayEdit() async {
        let (service, _) = makeService(mode: .block)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        service.end(runId: first.run)
        let verdict = await service.checkEdit(runId: second.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(verdict, .allow)
    }

    func test_oneNoticePerRunAndFileWhileTheConflictLasts() async {
        let (service, notices) = makeService(mode: .warn)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        for _ in 0..<3 { _ = await service.checkEdit(runId: second.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true) }
        XCTAssertEqual(notices.all.count, 1, "an agent retrying must not spam the user")
    }

    func test_pathsOutsideTheCheckoutAndRunsOutsideGitAreNeverChecked() async {
        let (service, notices) = makeService(mode: .block)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/elsewhere/a.swift"], cwd: nil, enforce: true)
        let outside = await service.checkEdit(runId: second.run, paths: ["/elsewhere/a.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(outside, .allow)
        XCTAssertTrue(notices.all.isEmpty)

        let noGit = FileLeaseService(mode: { .block }, resolveIdentity: { _ in nil })
        let run = AgentRunID()
        noGit.begin(runId: run, threadId: AgentThreadID(), cwd: "/tmp/scratch")
        let verdict = await noGit.checkEdit(runId: run, paths: ["/tmp/scratch/a.txt"], cwd: nil, enforce: true)
        XCTAssertEqual(verdict, .allow)
        let unknown = await noGit.checkEdit(runId: AgentRunID(), paths: ["/tmp/scratch/a.txt"], cwd: nil, enforce: true)
        XCTAssertEqual(unknown, .allow, "a run the service never saw cannot be blocked")
    }

    func test_aWorktreeIsADifferentCheckoutSoTheSameRelativeFileDoesNotConflict() async {
        let main = RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: "main")
        let linked = RunRepoIdentity(repoRoot: "/work/app-wt", gitCommonDir: "/work/app/.git", branch: "feature")
        let service = FileLeaseService(mode: { .block }, resolveIdentity: { $0 == "/work/app" ? main : linked })
        let a = AgentRunID(), b = AgentRunID()
        service.begin(runId: a, threadId: AgentThreadID(), cwd: "/work/app")
        service.begin(runId: b, threadId: AgentThreadID(), cwd: "/work/app-wt")
        _ = await service.checkEdit(runId: a, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        let verdict = await service.checkEdit(runId: b, paths: ["/work/app-wt/a.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(verdict, .allow, "isolation by worktree is the escape hatch the conflict message offers")
    }

    func test_aThreadLookupFindsTheLiveRunForProvidersThatOnlyKnowTheThread() async {
        let (service, _) = makeService(mode: .block)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        let verdict = await service.checkEdit(threadId: second.thread, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        guard case .deny = verdict else { return XCTFail("expected a refusal, got \(verdict)") }
        let none = await service.checkEdit(threadId: AgentThreadID(), paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(none, .allow)
    }

    func test_changeCallbackFiresOnlyWhenTheLeasedSetChanges() async {
        let (service, _) = makeService(mode: .warn)
        let count = ChangeCounter()
        service.onChange = { count.increment() }
        let run = start(service).run
        _ = await service.checkEdit(runId: run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        _ = await service.checkEdit(runId: run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(count.value, 1, "a renewal changes nothing the header shows")
        service.end(runId: run)
        XCTAssertEqual(count.value, 2)
        service.end(runId: run)
        XCTAssertEqual(count.value, 2)
    }

    func test_staleWriteRefusalsReachTheUserOncePerFile() {
        let (service, notices) = makeService(mode: .warn)
        let run = start(service).run
        let text = "Error: /work/app/a.swift changed since you last read it (modified by another process or session), so it was not overwritten. Read it again, then rewrite it."
        XCTAssertEqual(StaleWriteRefusal.message(in: "noise\n\(text)\nmore"), text)
        XCTAssertEqual(StaleWriteRefusal.path(in: text), "/work/app/a.swift")
        XCTAssertNil(StaleWriteRefusal.message(in: "wrote 3 lines"))
        XCTAssertNil(StaleWriteRefusal.message(in: "// a comment: this value changed since you last read it, so it was not overwritten"),
                     "a file that merely contains the phrase is not a refusal")
        service.reportStaleWrite(runId: run, path: StaleWriteRefusal.path(in: text), message: text)
        service.reportStaleWrite(runId: run, path: StaleWriteRefusal.path(in: text), message: text)
        XCTAssertEqual(notices.all.map(\.kind), [.staleWriteRefused])
        XCTAssertEqual(notices.all.first?.path, "/work/app/a.swift")
        service.reportStaleWrite(runId: AgentRunID(), path: nil, message: text)
        XCTAssertEqual(notices.all.count, 1, "a run the host does not own is ignored")
    }

    func test_racingRunsCannotBothWinTheSameFile() async {
        let (service, notices) = makeService(mode: .warn)
        let runs = (0..<8).map { _ in start(service) }
        let verdicts = await withTaskGroup(of: PreEditVerdict.self) { group in
            for item in runs {
                group.addTask { await service.checkEdit(runId: item.run, paths: ["/work/app/race.swift"], cwd: nil, enforce: true) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(verdicts.filter { $0 == .allow }.count, 1, "exactly one run owns the file; every other run is warned")
        XCTAssertEqual(notices.all.count, 7)
    }

    func test_aRefusedEditLeasesNoneOfItsFilesInBlockModeButAWarnedOneLeasesTheFreeOnes() async {
        let (blocking, _) = makeService(mode: .block)
        let a = start(blocking), b = start(blocking)
        _ = await blocking.checkEdit(runId: a.run, paths: ["/work/app/held.swift"], cwd: nil, enforce: true)
        _ = await blocking.checkEdit(runId: b.run, paths: ["/work/app/held.swift", "/work/app/free.swift"], cwd: nil, enforce: true)
        XCTAssertNil(blocking.store.activeLeases().first { $0.path == "free.swift" })

        let (warning, _) = makeService(mode: .warn)
        let c = start(warning), d = start(warning)
        _ = await warning.checkEdit(runId: c.run, paths: ["/work/app/held.swift"], cwd: nil, enforce: true)
        _ = await warning.checkEdit(runId: d.run, paths: ["/work/app/held.swift", "/work/app/free.swift"], cwd: nil, enforce: true)
        XCTAssertEqual(warning.store.activeLeases().first { $0.path == "free.swift" }?.holder.runID, d.run)
        XCTAssertEqual(warning.store.activeLeases().first { $0.path == "held.swift" }?.holder.runID, c.run)
    }

    func test_theDistillHooksFileDeniesNothingItselfAndNamesTheServiceMode() throws {
        let data = try FileLeaseHooks.contents(serviceExecutable: "/Apps/Mac Code/RemoteCodeDistillService")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try XCTUnwrap((object["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group["matcher"] as? String, "write|search_replace|apply_patch|edit|hashline_edit")
        let hook = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["type"] as? String, "command")
        XCTAssertEqual(hook["command"] as? String, "'/Apps/Mac Code/RemoteCodeDistillService' lease-hook",
                       "a path with spaces must survive the shell")
        XCTAssertEqual(hook["timeout"] as? Int, 10)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try FileLeaseHooks.write(serviceExecutable: "/x/service", in: dir)
        XCTAssertEqual(url.lastPathComponent, "concurrent-work-hooks.json")
        XCTAssertEqual(try Data(contentsOf: url), try FileLeaseHooks.contents(serviceExecutable: "/x/service"))
        XCTAssertEqual(FileLeaseHooks.shellQuoted("it's"), "'it'\\''s'")
    }

    func test_theHookEnvironmentKeyIsHostOwnedSoALaunchConfigCannotInjectItsOwn() {
        XCTAssertTrue(AgentHostEnvironmentMerge.isHostInjectedKey(FileLeaseHooks.environmentKey))
        let merged = AgentHostEnvironmentMerge.preserveHostInjects(
            launch: [FileLeaseHooks.environmentKey: "/stale/hooks.json"],
            request: [FileLeaseHooks.environmentKey: "/fresh/hooks.json"]
        )
        XCTAssertEqual(merged[FileLeaseHooks.environmentKey], "/fresh/hooks.json")
        XCTAssertNil(AgentHostEnvironmentMerge.preserveHostInjects(launch: [FileLeaseHooks.environmentKey: "/stale"], request: [:])[FileLeaseHooks.environmentKey])
    }

    func test_claudeBridgeAnswersWithTheVerdictAndTheEditIsAllowedWhenNothingChecks() async throws {
        let (service, _) = makeService(mode: .block)
        let first = start(service), second = start(service)
        _ = await service.checkEdit(runId: first.run, paths: ["/work/app/a.swift"], cwd: nil, enforce: true)
        let line = #"{"type":"lease_check_request","request_id":"tu-1","tool_name":"Edit","tool_input":{"file_path":"/work/app/a.swift"}}"#
        XCTAssertTrue(ClaudeAgentSDKBridgeAdapter.isLeaseCheckRequest(line))
        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.isLeaseCheckRequest(#"{"type":"assistant"}"#))

        let denied = await ClaudeAgentSDKBridgeAdapter.leaseCheckResponse(forLine: line, threadId: second.thread, checker: service)
        XCTAssertEqual(denied?["verdict"] as? String, "deny")
        XCTAssertEqual(denied?["request_id"] as? String, "tu-1")
        XCTAssertTrue((denied?["message"] as? String)?.contains("`a.swift`") == true)

        let unchecked = await ClaudeAgentSDKBridgeAdapter.leaseCheckResponse(forLine: line, threadId: second.thread, checker: nil)
        XCTAssertEqual(unchecked?["verdict"] as? String, "allow")
        let read = #"{"type":"lease_check_request","request_id":"tu-2","tool_name":"Read","tool_input":{"file_path":"/work/app/a.swift"}}"#
        let reading = await ClaudeAgentSDKBridgeAdapter.leaseCheckResponse(forLine: read, threadId: second.thread, checker: service)
        XCTAssertEqual(reading?["verdict"] as? String, "allow", "a read is never an edit")
    }

    func test_theBridgeScriptRegistersThePreEditHookForEveryEditTool() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"), encoding: .utf8)
        XCTAssertTrue(source.contains("PreToolUse: [{ matcher: 'Edit|Write|MultiEdit|NotebookEdit', hooks: [leaseCheckHook] }]"),
                      "a PreToolUse hook runs in every permission mode; canUseTool is skipped in full access")
        XCTAssertTrue(source.contains("command.type === 'lease_check_response'"))
        XCTAssertTrue(source.contains("LEASE_CHECK_TIMEOUT_MS"), "no answer in time must let the edit through")
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
