import XCTest
import CoreModel
import Persistence
import SocketServer
@testable import AgentRuntime
@testable import AppShell

final class ConcurrentWorkLeaseTests: XCTestCase {
    func test_policyDecisionOnlyActsOnTheFirstLocalMessageWhileOthersEdit() {
        typealias A = LocalRunConflictAction
        XCTAssertEqual(A.decide(policy: .warn, isFirstMessage: true, executionMode: .local, othersEditing: true), .proceed,
                       "warn is the default: the thread header says it, nothing moves")
        XCTAssertEqual(A.decide(policy: .autoWorktree, isFirstMessage: true, executionMode: .local, othersEditing: true), .useWorktree)
        XCTAssertEqual(A.decide(policy: .ask, isFirstMessage: true, executionMode: .local, othersEditing: true), .ask)
        XCTAssertEqual(A.decide(policy: .autoWorktree, isFirstMessage: true, executionMode: .local, othersEditing: false), .proceed,
                       "nobody else is editing: no reason to leave the project folder")
        XCTAssertEqual(A.decide(policy: .autoWorktree, isFirstMessage: false, executionMode: .local, othersEditing: true), .proceed,
                       "a running conversation keeps the checkout its first message chose")
        XCTAssertEqual(A.decide(policy: .autoWorktree, isFirstMessage: true, executionMode: .worktree, othersEditing: true), .proceed,
                       "a thread already in a worktree is isolated")
    }

    func test_settingsDefaultToWarnAndSurviveARoundTripAndGarbage() throws {
        XCTAssertEqual(AppSettings().concurrentLeaseMode, .warn)
        XCTAssertEqual(AppSettings().localRunConflictPolicy, .warn)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"diffWordWrap\":true}".utf8))
        XCTAssertEqual(legacy.concurrentLeaseMode, .warn, "settings saved by an older build keep working")
        var changed = AppSettings()
        changed.concurrentLeaseMode = .block
        changed.localRunConflictPolicy = .autoWorktree
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(again.concurrentLeaseMode, .block)
        XCTAssertEqual(again.localRunConflictPolicy, .autoWorktree)
        let garbled = try JSONDecoder().decode(AppSettings.self, from: Data("{\"concurrentLeaseMode\":\"strict\",\"localRunConflictPolicy\":7}".utf8))
        XCTAssertEqual(garbled.concurrentLeaseMode, .warn, "an unknown value must never silently become a stricter mode")
        XCTAssertEqual(garbled.localRunConflictPolicy, .warn)
    }

    @MainActor
    func test_settingViewModelPersistsBothChoices() throws {
        let appSupport = NSTemporaryDirectory() + "RC2LeaseSettings-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let vm = SettingsViewModel(context: context)
        vm.setConcurrentLeaseMode(.block)
        vm.setLocalRunConflictPolicy(.ask)
        let stored = SettingsStore(db: context.db).reload()
        XCTAssertEqual(stored.concurrentLeaseMode, .block)
        XCTAssertEqual(stored.localRunConflictPolicy, .ask)
    }

    func test_everyChoiceTitleIsTranslatedInEveryLanguage() {
        let titles = FileLeaseMode.allCases.map { ConcurrentWorkSettingsSection.title($0) }
            + LocalRunConflictPolicy.allCases.map { ConcurrentWorkSettingsSection.title($0) }
        let table = AppLocalization.translatedKeys
        for language in ["pt-BR", "es", "fr", "ar", "zh-Hans", "zh-Hant"] {
            for title in titles {
                XCTAssertNotNil(table[language]?[title], "\(language) has no text for \(title)")
            }
        }
    }

    @MainActor
    func test_distillGetsTheHostHooksFileAndOtherProvidersDoNot() throws {
        // WHY: the lease check for Distill rides on GROK_EXTRA_HOOKS_FILE; it must name the host's own file and
        // must not leak to providers that do not read it.
        let appSupport = NSTemporaryDirectory() + "RC2LeaseHooksEnv-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        context.leaseHooksServiceExecutable = "/opt/MacCode/RemoteCodeDistillService"
        let router = AppCommandRouter(context: context)
        let env = router.providerEnvironment(provider: .distill, instanceId: nil)
        let path = try XCTUnwrap(env[FileLeaseHooks.environmentKey])
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedSupport = context.appSupportDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(resolvedPath.hasPrefix(resolvedSupport), "the file lives in MacCode's own app-support dir: \(path) vs \(context.appSupportDirectory.path)")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let group = try XCTUnwrap(((object["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap(((group["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        XCTAssertEqual(command, "'/opt/MacCode/RemoteCodeDistillService' lease-hook")
        XCTAssertNil(router.providerEnvironment(provider: .claude, instanceId: nil)[FileLeaseHooks.environmentKey])
        XCTAssertNil(router.providerEnvironment(provider: .codex, instanceId: nil)[FileLeaseHooks.environmentKey])
    }

    @MainActor
    func test_aResidentSessionStillGetsAnAnswerThroughTheThreadsLiveRun() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2LeaseResident-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let thread = AgentThread(title: "t", provider: .distill, model: "m")
        try context.threadRepo.upsert(thread)
        let oldRun = AgentRun(threadId: thread.id, provider: .distill, model: "m", status: .completed)
        try context.runRepo.upsert(oldRun)
        do {
            _ = try router.leaseCheckRun(thread: thread.id, claimedRun: oldRun.id, capability: "stale", context: context)
            XCTFail("a thread with no live run has nothing to speak for")
        } catch {}
        do {
            _ = try router.leaseCheckRun(thread: AgentThreadID(), claimedRun: oldRun.id, capability: "stale", context: context)
            XCTFail("a run id from another thread is never accepted")
        } catch {}
    }

    @MainActor
    func test_peerTasksKeepTheCallersCheckoutUnlessTheWorktreePolicyIsOn() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2LeasePeerCwd-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let run = AgentRunID()

        let unchanged = await router.isolatedPeerCwd(repo, runID: run)
        XCTAssertEqual(unchanged, repo, "warn keeps today's behavior")

        var settings = SettingsStore(db: context.db).load()
        settings.localRunConflictPolicy = .autoWorktree
        SettingsStore(db: context.db).save(settings)
        let isolatedPath = await router.isolatedPeerCwd(repo, runID: run)
        let isolated = try XCTUnwrap(isolatedPath)
        defer { try? FileManager.default.removeItem(atPath: isolated) }
        XCTAssertNotEqual(isolated, repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated + "/a.txt"), "the peer gets a real checkout of the caller's repo")
        let main = try XCTUnwrap(GitDiff.repoIdentity(in: repo)), linked = try XCTUnwrap(GitDiff.repoIdentity(in: isolated))
        XCTAssertEqual(main.gitCommonDir, linked.gitCommonDir, "still the same repository, so Activity relates the two")
        XCTAssertNotEqual(main.repoRoot, linked.repoRoot)

        let outside = NSTemporaryDirectory()
        let notGit = await router.isolatedPeerCwd(outside, runID: AgentRunID())
        XCTAssertEqual(notGit, outside, "no repository, nothing to isolate")
        let none = await router.isolatedPeerCwd(nil, runID: run)
        XCTAssertNil(none)
    }

    @MainActor
    func test_autoWorktreePolicyMovesTheFirstMessageOfALocalThreadWhenAnotherRunIsEditing() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2LeaseFirstSend-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let workspace = try router.createWorkspace(name: "leases", cwd: repo)
        var thread = AgentThread(projectId: ProjectID(), workspaceId: workspace.id, title: "new", provider: .distill, model: "m", status: .completed)
        try context.threadRepo.upsert(thread)

        // Another run editing the same checkout.
        let other = AgentThread(projectId: ProjectID(), workspaceId: workspace.id, title: "Other work", provider: .distill, model: "m", status: .running)
        try context.threadRepo.upsert(other)
        let otherRun = AgentRun(threadId: other.id, provider: .distill, model: "m", status: .running)
        try context.runRepo.upsert(otherRun)
        let identity = try XCTUnwrap(GitDiff.repoIdentity(in: repo))
        let touches = AgentRunFileTouchRepository(db: context.db)
        try touches.saveIdentity(runId: otherRun.id, threadId: other.id, identity: identity)
        try touches.recordTouches(runId: otherRun.id, threadId: other.id, repoRoot: identity.repoRoot,
                                  touches: [ProviderFileTouch(path: "a.txt", kind: .edit)])
        context.concurrentWorkIndex = ConcurrentWorkIndex(db: context.db)

        var warnThread = thread
        try await router.applyLocalRunConflictPolicy(to: &warnThread, alreadyStarted: false)
        XCTAssertEqual(warnThread.executionMode, .local, "warn never moves the thread")

        var settings = SettingsStore(db: context.db).load()
        settings.localRunConflictPolicy = .autoWorktree
        SettingsStore(db: context.db).save(settings)
        var started = thread
        try await router.applyLocalRunConflictPolicy(to: &started, alreadyStarted: true)
        XCTAssertEqual(started.executionMode, .local, "only the first message may move a thread")

        try await router.applyLocalRunConflictPolicy(to: &thread, alreadyStarted: false)
        XCTAssertEqual(thread.executionMode, .worktree)
        XCTAssertEqual(thread.baseBranch, identity.branch)
        let stored = try XCTUnwrap(try context.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.executionMode, .worktree, "the choice persists, so the run reopens in the same worktree")
        XCTAssertEqual(stored.baseBranch, identity.branch)

        // Ask: the user's answer decides.
        var asked = AgentThread(projectId: ProjectID(), workspaceId: workspace.id, title: "asked", provider: .distill, model: "m", status: .completed)
        try context.threadRepo.upsert(asked)
        settings.localRunConflictPolicy = .ask
        SettingsStore(db: context.db).save(settings)
        var shown: ConcurrentWorkSnapshot?
        router.localRunConflictAsker = { snapshot in shown = snapshot; return .runHere }
        try await router.applyLocalRunConflictPolicy(to: &asked, alreadyStarted: false)
        XCTAssertEqual(asked.executionMode, .local)
        XCTAssertEqual(shown?.runs.first?.threadTitle, "Other work", "the dialog names who is editing")
        router.localRunConflictAsker = { _ in .cancel }
        do {
            try await router.applyLocalRunConflictPolicy(to: &asked, alreadyStarted: false)
            XCTFail("Cancel must stop the send")
        } catch {}
        router.localRunConflictAsker = { _ in .newWorktree }
        try await router.applyLocalRunConflictPolicy(to: &asked, alreadyStarted: false)
        XCTAssertEqual(asked.executionMode, .worktree)
    }

    private func makeRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "rc2-lease-repo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args)")
        }
        try git(["init", "-q", "-b", "main"])
        try "a\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])
        return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }
}
