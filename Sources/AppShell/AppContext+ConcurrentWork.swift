import AgentRuntime
import CoreModel
import Foundation
import Persistence

extension AppContext {
    /// Builds the lease service and connects it to the coordinator, the provider adapters, the notice banner
    /// and the surfaces' "also editing" feed.
    func installConcurrentWork(codex: CodexAppServerAdapter, claude: AgentProviderAdapter) {
        let db = self.db
        let botStore = self.botStore
        let threadRepo = self.threadRepo
        let service = FileLeaseService(
            mode: { SettingsStore(db: db).load().concurrentLeaseMode },
            describe: { threadID in
                let title = (try? threadRepo.listChrome(ids: [threadID]))?[threadID]?.title ?? ""
                var label: String?
                if let conversation = try? botStore.conversationLinked(to: threadID),
                   let bot = try? botStore.get(id: conversation.botID) {
                    label = "@\(bot.handle)"
                }
                return (title, label)
            }
        )
        service.onChange = { NotificationCenter.default.post(name: .concurrentWorkDidChange, object: nil) }
        service.onNotice = { [weak self] notice in
            Task { @MainActor in self?.postLeaseNotice(notice) }
        }
        fileLeaseService = service
        coordinator.fileLeaseService = service
        codex.preEditChecker = service
        (claude as? ClaudeAgentSDKBridgeAdapter)?.preEditChecker = service
        let index = concurrentWorkIndex
        ConcurrentWorkFeed.shared.provider = { cwd, excludingThread in
            ConcurrentWorkContext.snapshot(cwd: cwd, excludingThread: excludingThread, index: index)
        }
    }

    /// The hooks file Distill loads next to its own, or nil when the service binary is not available.
    func leaseHooksFileURL() -> URL? {
        guard let executable = leaseHooksServiceExecutable ?? AgentSkillInstaller.resolveServiceBinary()?.path else { return nil }
        return try? FileLeaseHooks.write(
            serviceExecutable: executable,
            in: appSupportDirectory.appendingPathComponent("concurrent-work", isDirectory: true)
        )
    }

    @MainActor
    private func postLeaseNotice(_ notice: FileLeaseNotice) {
        let settings = SettingsStore(db: db).load()
        guard settings.notificationActionAlertsEnabled else { return }
        let title: String
        switch notice.kind {
        case .conflictWarned: title = L("File in use by another run")
        case .leaseDenied: title = L("Edit blocked: file in use")
        case .staleWriteRefused: title = L("Write refused: file changed")
        }
        let body: String
        if let holder = notice.holder {
            let name = holder.threadTitle.isEmpty ? L("Untitled") : holder.threadTitle
            body = L("%1$@ is being edited by “%2$@”.", notice.path, [name, holder.botLabel].compactMap { $0 }.joined(separator: " · "))
        } else {
            body = L("A write was refused because the file changed since the agent last read it. The agent reads it again before retrying.")
        }
        let content = RemoteCodeNotificationContent(
            identifier: "concurrent-work.\(notice.runID.description).\(notice.kind.rawValue).\(notice.path)",
            title: title,
            body: body,
            categoryIdentifier: RemoteCodeNotificationContent.threadUpdateCategoryIdentifier,
            threadIdentifier: notice.threadID.value.uuidString,
            userInfo: ["threadId": notice.threadID.value.uuidString, "runId": notice.runID.value.uuidString],
            soundEnabled: false
        )
        SystemNotifier.shared.post(content, settings: settings)
    }
}

/// Reads the live runs that share a checkout with `cwd`.
enum ConcurrentWorkContext {
    static func snapshot(cwd: String, excludingThread: AgentThreadID?, index: ConcurrentWorkIndex) -> ConcurrentWorkSnapshot {
        guard let identity = GitDiff.repoIdentity(in: cwd),
              let runs = try? index.liveRuns(repoCommonDir: identity.gitCommonDir) else { return .empty }
        let here = runs.filter {
            $0.threadID != excludingThread && sameCheckout($0.worktreePath, identity.repoRoot) && !$0.editingFiles.isEmpty
        }
        return ConcurrentWorkSnapshot(runs: here, cwdPrefix: RunFileTouchPaths.cwdPrefix(cwd: cwd, repoRoot: identity.repoRoot))
    }

    static func sameCheckout(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}
