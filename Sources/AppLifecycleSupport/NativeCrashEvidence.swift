import Foundation
import Darwin

/// Copies GhosttyKit's crash evidence into RemoteCode's diagnostics folder.
///
/// GhosttyKit's embedded Sentry/Breakpad writes a minidump into its Sentry
/// database (`<Caches>/com.mitchellh.ghostty/sentry/<run>.run/`) and, on the
/// next start, hands the envelope to Ghostty's transport, which saves a
/// `.ghosttycrash` file under `$XDG_STATE_HOME/ghostty/crash`. The next
/// `ghostty_init` cleans the run folders up, so this must run at launch,
/// before anything can start Ghostty. Sources are only read, never changed;
/// the Ghostty folders are shared with Ghostty.app.
public enum GhosttyCrashHarvester {
    public static let fileExtensions: Set<String> = ["dmp", "envelope", "ghosttycrash"]
    /// Oldest copies beyond this count are deleted from the destination.
    public static let maxRetainedFiles = 20

    public static func defaultSourceDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var sources: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            sources.append(caches.appendingPathComponent("com.mitchellh.ghostty/sentry", isDirectory: true))
        }
        let stateHome = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".local/state", isDirectory: true)
        sources.append(stateHome.appendingPathComponent("ghostty/crash", isDirectory: true))
        return sources
    }

    /// Copies the crash files that rank among the newest `maxRetainedFiles`
    /// (counting copies already kept) and are not copied yet; returns the new
    /// copies, all of which are still on disk afterwards. A source older than
    /// everything kept is never copied, so a relaunch with the same inputs
    /// copies nothing: pruned files do not come back.
    ///
    /// The folders are shared with Ghostty.app, so a copy can be Ghostty.app's
    /// own crash rather than RemoteCode's.
    @discardableResult
    public static func harvest(
        from sources: [URL],
        into destination: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        struct Entry {
            let target: URL
            let source: URL?
            let modified: Date
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }

        let kept = ((try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []).map { Entry(target: $0, source: nil, modified: modified($0)) }
        let keptNames = Set(kept.map(\.target.lastPathComponent))

        var candidates: [Entry] = []
        for source in sources {
            guard let enumerator = fileManager.enumerator(
                at: source,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else { continue }
            let rootComponents = source.standardizedFileURL.pathComponents
            for case let file as URL in enumerator {
                guard fileExtensions.contains(file.pathExtension.lowercased()),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                // Flatten the path below the source so files from different run
                // folders cannot collide.
                let relative = file.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
                let name = relative.joined(separator: "--")
                guard !keptNames.contains(name) else { continue }
                candidates.append(Entry(
                    target: destination.appendingPathComponent(name, isDirectory: false),
                    source: file,
                    modified: modified(file)
                ))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Newest first; the name breaks ties so the ranking is stable across launches.
        let ranked = (kept + candidates).sorted {
            $0.modified != $1.modified
                ? $0.modified > $1.modified
                : $0.target.lastPathComponent < $1.target.lastPathComponent
        }
        let retained = ranked.prefix(maxRetainedFiles)
        let toCopy = retained.filter { $0.source != nil }
        guard !toCopy.isEmpty else { return [] }

        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied: [URL] = []
        for entry in toCopy {
            guard let source = entry.source,
                  (try? fileManager.copyItem(at: source, to: entry.target)) != nil else { continue }
            // Keep the source's date so the next launch ranks the copy the same way.
            try? fileManager.setAttributes([.modificationDate: entry.modified], ofItemAtPath: entry.target.path)
            copied.append(entry.target)
        }
        for entry in ranked.dropFirst(maxRetainedFiles) where entry.source == nil {
            try? fileManager.removeItem(at: entry.target)
        }
        return copied
    }
}

/// Recovers how a previous run that left a stale marker actually ended, from
/// launchd's unified-log line (e.g. `exited due to exit(1), ran for 35005804ms`
/// or `exited due to SIGKILL | sent by ...`). A run launched outside launchd
/// (from a terminal) has no such line and is reported as unknown. Only a line
/// under the app's own launchd label counts: the pid may have been reused by
/// another launchd job that exited later in the window.
public enum PreviousRunExitStatus {
    /// Runs `/usr/bin/log` with the given arguments; returns stdout, or nil on
    /// failure or timeout.
    public typealias LogRunner = (_ arguments: [String], _ timeout: TimeInterval) -> String?

    /// Searches from just before the last sign of life to a few hours later:
    /// heartbeats stop during a main-thread hang, so death can come much later.
    static let windowBefore: TimeInterval = 5
    static let windowAfter: TimeInterval = 3 * 60 * 60
    static let timeout: TimeInterval = 30

    /// The lifecycle.log line for the previous run's exit. `bundleIdentifier`
    /// is this app's: a previous run sharing the App Support has the same one.
    public static func lifecycleLine(
        pid: pid_t,
        lastAlive: Date?,
        bundleIdentifier: String?,
        now: Date = Date(),
        runLog: LogRunner = runLogShow
    ) -> String {
        guard let lastAlive,
              let bundleIdentifier, !bundleIdentifier.isEmpty,
              let output = runLog(
                  logShowArguments(pid: pid, lastAlive: lastAlive, bundleIdentifier: bundleIdentifier, now: now),
                  timeout
              ),
              let reason = launchdExitReason(inLogOutput: output, pid: pid, bundleIdentifier: bundleIdentifier) else {
            return "previous_run_exit pid=\(pid) launchd=unknown"
        }
        return "previous_run_exit pid=\(pid) launchd=\"\(reason)\""
    }

    static func logShowArguments(pid: pid_t, lastAlive: Date, bundleIdentifier: String, now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let end = min(now, lastAlive.addingTimeInterval(windowAfter))
        return [
            "show", "--style", "compact",
            "--start", formatter.string(from: lastAlive.addingTimeInterval(-windowBefore)),
            "--end", formatter.string(from: end),
            "--predicate",
            "process == \"launchd\" AND subsystem CONTAINS \"/\(launchdLabelPrefix(bundleIdentifier))\" "
                + "AND subsystem ENDSWITH \"[\(pid)]\" AND eventMessage BEGINSWITH \"exited\""
        ]
    }

    /// LaunchServices labels an app's job `application.<bundle id>.<numbers>`,
    /// sometimes followed by `.<instance UUID>`.
    static func launchdLabelPrefix(_ bundleIdentifier: String) -> String {
        "application.\(bundleIdentifier)."
    }

    /// The `exited ...` text of launchd's line for `pid` under this app's
    /// label, or nil when absent. Compact lines look like
    /// `... launchd[1:1bf2efa] [gui/501/<label> [15080]:] exited due to exit(1), ran for 75ms`.
    public static func launchdExitReason(inLogOutput output: String, pid: pid_t, bundleIdentifier: String) -> String? {
        let tag = " [\(pid)]:] "
        let labelPrefix = launchdLabelPrefix(bundleIdentifier)
        for line in output.split(separator: "\n") {
            guard let tagRange = line.range(of: tag) else { continue }
            // The label is the last path component before the pid; the rest of
            // it must be LaunchServices' numbers, plus the instance UUID it
            // appends to some launches, so `<id>.debug` and helper jobs with
            // the reused pid do not match.
            let label = line[..<tagRange.lowerBound].split(separator: "/").last ?? ""
            guard label.hasPrefix(labelPrefix) else { continue }
            let suffix = label.dropFirst(labelPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard suffix.allSatisfy({ part in
                !part.isEmpty && (part.allSatisfy(\.isNumber) || UUID(uuidString: String(part)) != nil)
            }) else { continue }
            let reason = line[tagRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if reason.hasPrefix("exited") {
                return reason.replacingOccurrences(of: "\"", with: "'")
            }
        }
        return nil
    }

    public static func runLogShow(arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
