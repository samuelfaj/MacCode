import CoreModel
import Foundation
import AppKit
import AppLifecycleSupport
import os
import Persistence

@main
@MainActor
struct RemoteCodeMain {
    static func main() {
        // App chrome and Foundation/AppKit errors stay English regardless of the macOS language.
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        // Priority: explicit env override -> bundle-id derivation -> .debug
        let channel: ReleaseChannel
        if let envRaw = ProcessInfo.processInfo.environment["RC2_CHANNEL"],
           let envChannel = ReleaseChannel(rawValue: envRaw) {
            channel = envChannel
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            channel = ReleaseChannel.channelFromBundleID(bundleID)
        }
        if CommandLine.arguments == [CommandLine.arguments[0], "--database-schema-version"] {
            print(Persistence.Schema.currentVersion)
            return
        }
        let rollbackFlag = "--rollback-host"
        let rollingBack = CommandLine.arguments.contains(rollbackFlag)
        if rollingBack && (CommandLine.arguments.contains("--inspect-database-backup") || CommandLine.arguments.contains("--restore-database-backup") || CommandLine.arguments.contains("--create-database-backup")) {
            fputs("Host rollback cannot combine with database inspect or restore.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let appSupportOverride = ProcessInfo.processInfo.environment["RC2_APP_SUPPORT"]
        let dbOverride = ProcessInfo.processInfo.environment["RC2_DB_PATH"]
        let restoreFlag = "--restore-database-backup"
        let restoresDatabase = CommandLine.arguments.contains(restoreFlag)
        let inspectFlag = "--inspect-database-backup"
        let inspectsDatabase = CommandLine.arguments.contains(inspectFlag)
        let createFlag = "--create-database-backup"
        let createsDatabase = CommandLine.arguments.contains(createFlag)
        // Optional trailing opt-in; the strict argument checks below see the command without it.
        let quarantineFlag = "--quarantine-orphans"
        let quarantinesOrphans = restoresDatabase && CommandLine.arguments.count > 3 && CommandLine.arguments.last == quarantineFlag
        let databaseArguments = quarantinesOrphans ? Array(CommandLine.arguments.dropLast()) : CommandLine.arguments
        if CommandLine.arguments.contains(quarantineFlag) && !quarantinesOrphans {
            fputs("--quarantine-orphans is only valid as the last argument of --restore-database-backup.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let repairsContextReceipts = CommandLine.arguments.contains("--repair-context-receipts")
        if repairsContextReceipts {
            guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--repair-context-receipts",
                  ProcessInfo.processInfo.environment["RC2_SCHEDULED_TASK_AGENT"] != "1" else {
                fputs("Context receipt repair accepts no arguments or mixed operations.\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        if restoresDatabase || inspectsDatabase || createsDatabase {
            let operationFlags = [restoreFlag, inspectFlag, createFlag].filter { CommandLine.arguments.contains($0) }
            let hasScheduledAgentFlag = CommandLine.arguments.contains(where: { $0 == "--scheduled-task-agent" || $0 == "--scheduled-task-agent-unregister" })
                || ProcessInfo.processInfo.environment["RC2_SCHEDULED_TASK_AGENT"] == "1"
            let validArguments: Bool
            if operationFlags.count != 1 || hasScheduledAgentFlag || rollingBack {
                validArguments = false
            } else if inspectsDatabase || createsDatabase {
                validArguments = databaseArguments.count == 3 && databaseArguments[1] == operationFlags[0]
                    && !databaseArguments.contains("--restore-review") && !databaseArguments.contains(quarantineFlag)
            } else if databaseArguments.count == 3 && databaseArguments[1] == restoreFlag && !databaseArguments.contains(quarantineFlag) {
                validArguments = true
            } else {
                validArguments = databaseArguments.count == 5
                    && databaseArguments[1] == restoreFlag
                    && databaseArguments[3] == "--restore-review"
                    && databaseArguments.filter({ $0 == "--restore-review" }).count == 1
                    && !databaseArguments.contains(quarantineFlag)
            }
            guard validArguments else {
                fputs("Database backup operation has mixed flags or invalid arguments.\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        if !rollingBack && CommandLine.arguments.contains("--scheduled-task-agent-unregister") {
            do {
                try ScheduledTaskAgentServiceManager().unregister()
                print("Scheduled Tasks background agent unregistered.")
            } catch {
                fputs("Unable to unregister Scheduled Tasks background agent: \(error)\n", stderr)
            }
            return
        }

        let app = NSApplication.shared
        RemoteCodeAppearance.apply(to: app)
        let isScheduledTaskAgent = CommandLine.arguments.contains("--scheduled-task-agent")
            || ProcessInfo.processInfo.environment["RC2_SCHEDULED_TASK_AGENT"] == "1"
        if isScheduledTaskAgent && !rollingBack {
            // Schedules run in-process in the interactive app. A leftover LaunchAgent
            // install must not dual-claim: unregister and exit immediately.
            do {
                try ScheduledTaskAgentServiceManager().unregister()
                print("Scheduled Tasks now run inside MacCode; background agent unregistered.")
            } catch {
                fputs("Unable to unregister legacy Scheduled Tasks agent: \(error)\n", stderr)
            }
            return
        }

        // S-F8: one process per App Support directory. A second instance would
        // share the database, port and run marker; hand focus to the first and
        // exit before touching any of them. The isolated sandbox has its own
        // App Support, so it never contends with the user's app.
        let instanceLock: AppInstanceLock?
        let appSupportDirectory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
        switch AppInstanceLock.acquire(directory: appSupportDirectory) {
        case .acquired(let lock):
            instanceLock = lock
        case .heldByOther(let holderPID):
            let holder = holderPID.map(String.init) ?? "unknown"
            Logger(subsystem: "io.remotecode.app", category: "lifecycle")
                .fault("app.second_instance_exit holder=\(holder, privacy: .public)")
            fputs("MacCode is already running for \(appSupportDirectory.path) (pid \(holder)); exiting.\n", stderr)
            if restoresDatabase || inspectsDatabase || createsDatabase || rollingBack || repairsContextReceipts { exit(EXIT_FAILURE) }
            if let holderPID, !LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
                NSRunningApplication(processIdentifier: holderPID)?.activate()
            }
            return
        case .unavailable(let code):
            Logger(subsystem: "io.remotecode.app", category: "lifecycle")
                .error("app.instance_lock_unavailable errno=\(code, privacy: .public)")
            instanceLock = nil
        }

        if repairsContextReceipts {
            guard let instanceLock else {
                fputs("Context receipt repair requires an exclusive host lock.\n", stderr)
                exit(EXIT_FAILURE)
            }
            withExtendedLifetime(instanceLock) {
                do {
                    let current = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
                    try HostScopedSessionBackup.recoverInterruptedRestore(currentURL: current, appSupport: appSupportDirectory)
                    let report = try BotContextReceiptRepair.run(databaseURL: current, appSupport: appSupportDirectory)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(report), as: UTF8.self))
                    if !report.failures.isEmpty { exit(EXIT_FAILURE) }
                } catch {
                    fputs("Context receipt repair failed; cleanup remains unconfirmed.\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }

        if rollingBack {
            guard let instanceLock, CommandLine.arguments.count >= 3,
                  CommandLine.arguments[1] == rollbackFlag,
                  !CommandLine.arguments.dropFirst(2).contains(rollbackFlag),
                  !CommandLine.arguments.dropFirst(2).contains("--restore-database-backup"),
                  !CommandLine.arguments.dropFirst(2).contains("--inspect-database-backup") else {
                fputs("Host rollback requires an exclusive host lock, one target app path, and no mixed database operation.\n", stderr)
                exit(EXIT_FAILURE)
            }
            let separator: Int?
            if CommandLine.arguments.count == 3 {
                separator = nil
            } else if CommandLine.arguments[3] == "--" {
                separator = 3
            } else {
                fputs("Host rollback accepts only explicit -- before forwarded arguments.\n", stderr)
                exit(EXIT_FAILURE)
            }
            withExtendedLifetime(instanceLock) {
                do {
                    let target = URL(fileURLWithPath: CommandLine.arguments[2])
                    let database = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
                    let executable = try HostDatabaseRollback.validate(databaseURL: database, targetURL: target, currentBundleURL: Bundle.main.bundleURL, currentBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    let forwarded = separator.map { Array(CommandLine.arguments[($0 + 1)...]) } ?? []
                    let args = [executable.path] + forwarded
                    let cargs = args.map { strdup($0) } + [nil]
                    cargs.withUnsafeBufferPointer { buffer in _ = execv(executable.path, buffer.baseAddress!) }
                    fputs("Unable to execute rollback target.\n", stderr)
                    exit(EXIT_FAILURE)
                } catch {
                    fputs("Host rollback refused: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            exit(EXIT_FAILURE)
        }

        if restoresDatabase || inspectsDatabase || createsDatabase {
            let operations = [restoreFlag, inspectFlag, createFlag].filter { CommandLine.arguments.contains($0) }
            let operationFlag = operations.first ?? ""
            guard let instanceLock, operations.count == 1,
                  CommandLine.arguments.filter({ $0 == operationFlag }).count == 1,
                  !CommandLine.arguments.contains("--scheduled-task-agent"),
                  !CommandLine.arguments.contains("--scheduled-task-agent-unregister"),
                  !CommandLine.arguments.contains("--rollback-host"),
                  let index = CommandLine.arguments.firstIndex(of: operationFlag),
                  CommandLine.arguments.count >= index + 2,
                  index + 2 == databaseArguments.count || (restoresDatabase && index + 4 == databaseArguments.count && databaseArguments[index + 2] == "--restore-review"),
                  CommandLine.arguments.filter({ $0 == "--restore-review" }).count <= 1,
                  restoresDatabase || !CommandLine.arguments.contains("--restore-review") else {
                fputs("Database backup operation requires exclusive host lock, one path, and no mixed flags.\n", stderr)
                exit(EXIT_FAILURE)
            }
            withExtendedLifetime(instanceLock) {
                do {
                    let current = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
                    try HostScopedSessionBackup.recoverInterruptedRestore(currentURL: current, appSupport: appSupportDirectory)
                    let backup = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    if createsDatabase {
                        try HostScopedSessionBackup.create(backupURL: backup, currentURL: current, appSupport: appSupportDirectory)
                        print("Database backup created: \(backup.path)")
                        return
                    }
                    if inspectsDatabase {
                        let review = try HostScopedSessionBackup.inspect(backupURL: backup)
                        let output: [String: Any] = [
                            "schema_version": review.database.schemaVersion, "review_fingerprint": review.fingerprint,
                            "agent_queue_ids": review.database.agentQueueIDs, "bot_queue_ids": review.database.botQueueIDs,
                            "routine_ids": review.database.routineIDs, "scheduled_task_ids": review.database.scheduledTaskIDs,
                            "requires_confirmation": review.requiresConfirmation,
                            "scoped_session_count": review.scopedSessionCount,
                            "adoption_policy": "Queues require an explicit force-send action. Schedules remain disabled until explicitly enabled."
                        ]
                        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                        return
                    }
                    var token: String?
                    if let reviewIndex = CommandLine.arguments.firstIndex(of: "--restore-review") {
                        guard CommandLine.arguments.filter({ $0 == "--restore-review" }).count == 1,
                              CommandLine.arguments.indices.contains(reviewIndex + 1) else {
                            throw SQLiteError.open("restore review requires one fingerprint")
                        }
                        token = CommandLine.arguments[reviewIndex + 1]
                    }
                    let recovery = try HostScopedSessionBackup.restore(backupURL: backup, currentURL: current, appSupport: appSupportDirectory, reviewToken: token, quarantineOrphans: quarantinesOrphans)
                    let quarantine = HostDatabaseRestore.quarantineURL(forRecovery: recovery)
                    if quarantinesOrphans, FileManager.default.fileExists(atPath: quarantine.path) {
                        print("Orphan rows were saved aside in: \(quarantine.path)")
                    }
                    print("Database restored without starting execution. Recovery backup: \(recovery.path)")
                } catch {
                    fputs("Database restore failed: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }

        guard let instanceLock else {
            fputs("MacCode cannot start without exclusive host lock.\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            let current = URL(fileURLWithPath: dbOverride ?? appSupportDirectory.appendingPathComponent("remotecode.sqlite").path)
            try HostScopedSessionBackup.recoverInterruptedRestore(currentURL: current, appSupport: appSupportDirectory)
        } catch {
            fputs("Interrupted database restore recovery failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        if LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            // Isolated iOS E2E: stay accessory and never steal the user's frontmost app.
            app.setActivationPolicy(.accessory)
        } else {
            app.setActivationPolicy(.regular)
        }
        let delegate = AppDelegate(channel: channel, appSupportOverride: appSupportOverride, dbOverride: dbOverride)
        app.delegate = delegate
        if !LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            app.activate(ignoringOtherApps: true)
        }
        withExtendedLifetime((delegate, instanceLock)) {
            app.run()
        }
    }
}
