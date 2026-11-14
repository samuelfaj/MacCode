import XCTest
import Darwin
@testable import AppLifecycleSupport

/// A RemoteCode run that died inside GhosttyKit's crash reporter left no `.ips`
/// and no lifecycle line saying how it ended. These tests pin the evidence the
/// next launch must keep: Ghostty's dump files (which Ghostty's next init
/// deletes) and launchd's exit reason for the dead pid.
final class GhosttyCrashHarvesterTests: XCTestCase {
    private func makeTempDir(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Crash-\(name)-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testCopiesDumpsAndEnvelopesFromRunFoldersWithoutTouchingTheSources() throws {
        let sentry = try makeTempDir("sentry")
        let crashState = try makeTempDir("state")
        let destination = try makeTempDir("dest").appendingPathComponent("ghostty-crash", isDirectory: true)
        let run = sentry.appendingPathComponent("d8f5dd31.run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data("minidump".utf8).write(to: run.appendingPathComponent("4a1b.dmp"))
        try Data("envelope".utf8).write(to: run.appendingPathComponent("4a1b.envelope"))
        try Data("{}".utf8).write(to: run.appendingPathComponent("session.json"))
        try Data().write(to: sentry.appendingPathComponent("d8f5dd31.run.lock"))
        try Data("report".utf8).write(to: crashState.appendingPathComponent("77c2.ghosttycrash"))

        let copied = GhosttyCrashHarvester.harvest(from: [sentry, crashState], into: destination)

        XCTAssertEqual(
            Set(copied.map(\.lastPathComponent)),
            ["d8f5dd31.run--4a1b.dmp", "d8f5dd31.run--4a1b.envelope", "77c2.ghosttycrash"],
            "only crash files are evidence; session and lock files are not"
        )
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("d8f5dd31.run--4a1b.dmp")), Data("minidump".utf8))
        // The folders are shared with Ghostty.app: harvesting must never remove its files.
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.appendingPathComponent("4a1b.dmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crashState.appendingPathComponent("77c2.ghosttycrash").path))

        XCTAssertEqual(
            GhosttyCrashHarvester.harvest(from: [sentry, crashState], into: destination), [],
            "a relaunch must not copy the same dump again"
        )
    }

    func testMissingSourcesHarvestNothing() throws {
        let destination = try makeTempDir("dest").appendingPathComponent("ghostty-crash", isDirectory: true)
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(GhosttyCrashHarvester.harvest(from: [missing], into: destination), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no dumps must not create an empty folder")
    }

    func testKeepsOnlyTheNewestCopies() throws {
        let source = try makeTempDir("src")
        let destination = try makeTempDir("dest")
        let limit = GhosttyCrashHarvester.maxRetainedFiles
        for index in 0..<(limit + 3) {
            let file = source.appendingPathComponent("dump-\(index).dmp")
            try Data([UInt8(index)]).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: file.path
            )
        }

        GhosttyCrashHarvester.harvest(from: [source], into: destination)

        let kept = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(kept.count, limit, "the diagnostics folder must stay bounded")
        XCTAssertFalse(kept.contains("dump-0.dmp"), "the oldest dump is the one dropped")
        XCTAssertTrue(kept.contains("dump-\(limit + 2).dmp"), "the newest dump must be kept")
    }

    /// Ghostty never prunes its crash folder, so it can hold more files than
    /// we keep. A dropped file must stay dropped: re-copying it on every launch
    /// would log the same old dump as fresh crash evidence each time.
    func testRelaunchDoesNotRecopyFilesThatWereDropped() throws {
        let source = try makeTempDir("src")
        let destination = try makeTempDir("dest").appendingPathComponent("ghostty-crash", isDirectory: true)
        let limit = GhosttyCrashHarvester.maxRetainedFiles
        for index in 0..<(limit + 3) {
            try writeDump(source.appendingPathComponent("dump-\(index).dmp"), age: Double(limit + 3 - index))
        }

        let first = GhosttyCrashHarvester.harvest(from: [source], into: destination)

        XCTAssertEqual(first.count, limit, "only what is kept may be reported as harvested")
        XCTAssertTrue(first.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "no reported copy may be deleted right away")
        XCTAssertFalse(first.contains { $0.lastPathComponent == "dump-0.dmp" }, "the oldest are never copied")
        for relaunch in 2...3 {
            XCTAssertEqual(
                GhosttyCrashHarvester.harvest(from: [source], into: destination), [],
                "launch \(relaunch) must not copy dropped files again"
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, limit)
    }

    /// Ghostty deletes its sentry run folders, so kept copies can outlive their
    /// sources. An old file still in Ghostty's state folder must not push out a
    /// newer kept copy, and must not be copied only to be deleted again.
    func testOldSourceDoesNotDisplaceNewerKeptCopies() throws {
        let source = try makeTempDir("src")
        let destination = try makeTempDir("dest").appendingPathComponent("ghostty-crash", isDirectory: true)
        let limit = GhosttyCrashHarvester.maxRetainedFiles
        let gone = try makeTempDir("gone")
        for index in 0..<limit {
            try writeDump(gone.appendingPathComponent("recent-\(index).dmp"), age: Double(index))
        }
        GhosttyCrashHarvester.harvest(from: [gone], into: destination)
        try writeDump(source.appendingPathComponent("ancient.ghosttycrash"), age: 1_000_000)

        XCTAssertEqual(GhosttyCrashHarvester.harvest(from: [source], into: destination), [])
        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
        XCTAssertEqual(kept.count, limit)
        XCTAssertFalse(kept.contains("ancient.ghosttycrash"))

        // A new crash still gets in, and the oldest kept copy makes room for it.
        try writeDump(source.appendingPathComponent("fresh.ghosttycrash"), age: -10)
        XCTAssertEqual(
            GhosttyCrashHarvester.harvest(from: [source], into: destination).map(\.lastPathComponent),
            ["fresh.ghosttycrash"]
        )
        let afterFresh = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
        XCTAssertEqual(afterFresh.count, limit)
        XCTAssertTrue(afterFresh.contains("fresh.ghosttycrash"))
        XCTAssertFalse(afterFresh.contains("recent-\(limit - 1).dmp"), "the oldest kept copy is the one dropped")
        XCTAssertEqual(GhosttyCrashHarvester.harvest(from: [source], into: destination), [])
    }

    /// The harvest must run before anything can start GhosttyKit, whose init
    /// deletes the previous run's dumps.
    func testLaunchHarvestsBeforeAnythingCanStartGhostty() throws {
        let appDelegate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/AppDelegate.swift")
        let source = try String(contentsOf: appDelegate, encoding: .utf8)
        let launch = try XCTUnwrap(source.range(of: "public func applicationDidFinishLaunching("))
        let body = source[launch.upperBound...]
        let harvest = try XCTUnwrap(body.range(of: "GhosttyCrashHarvester.harvest("), "launch must harvest Ghostty's crash files")
        let context = try XCTUnwrap(body.range(of: "AppContext("))
        XCTAssertLessThan(harvest.lowerBound, context.lowerBound, "the harvest must precede AppContext and everything after it")
        let codeBeforeHarvest = body[..<harvest.lowerBound]
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "let harvestedGhosttyCrashFiles =", with: "")
        XCTAssertFalse(codeBeforeHarvest.contains("Ghostty"), "nothing Ghostty may run before the harvest")
        XCTAssertFalse(codeBeforeHarvest.contains("context"), "nothing may build app state before the harvest")
    }

    private func writeDump(_ file: URL, age: TimeInterval) throws {
        try Data(file.lastPathComponent.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_790_000_000 - age)],
            ofItemAtPath: file.path
        )
    }

    func testDefaultSourcesFollowGhosttyCacheAndStateFolders() {
        let sources = GhosttyCrashHarvester.defaultSourceDirectories(environment: ["XDG_STATE_HOME": "/tmp/xdg-state"])
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("Library/Caches/com.mitchellh.ghostty/sentry") })
        XCTAssertTrue(sources.contains { $0.path == "/tmp/xdg-state/ghostty/crash" })
    }
}

final class PreviousRunExitStatusTests: XCTestCase {
    private let launchdOutput = """
    Timestamp               Ty Process[PID:TID]
    2026-10-05 19:37:03.385 Df launchd[1:1bf2efa] [gui/501/application.io.remotecode.desktop.1234 [60220]:] exited due to exit(1), ran for 35005804ms
    """

    private let bundleId = "io.remotecode.desktop"

    func testParsesLaunchdExitReasonForTheDeadPidOnly() {
        XCTAssertEqual(
            PreviousRunExitStatus.launchdExitReason(inLogOutput: launchdOutput, pid: 60220, bundleIdentifier: bundleId),
            "exited due to exit(1), ran for 35005804ms"
        )
        XCTAssertNil(
            PreviousRunExitStatus.launchdExitReason(inLogOutput: launchdOutput, pid: 6022, bundleIdentifier: bundleId),
            "a pid that is a prefix of another must not match its line"
        )
    }

    /// LaunchServices appends an instance UUID to the label of some launches.
    /// MacCode pid 73479 ran under such a label, so its exit(1) was recorded
    /// as `launchd=unknown` and the next launch could not say how it had died.
    func testParsesLaunchdExitReasonUnderALabelWithAnInstanceUUID() {
        let output = """
        2026-11-14 13:11:24.977 Df launchd[1:5ba5143] [gui/501/application.io.remotecode.desktop.806341756.806342527.7091F708-6936-4118-80DD-74A44F1024A9 [73479]:] exited due to exit(1), ran for 66780440ms
        """
        XCTAssertEqual(
            PreviousRunExitStatus.launchdExitReason(inLogOutput: output, pid: 73479, bundleIdentifier: bundleId),
            "exited due to exit(1), ran for 66780440ms"
        )
    }

    /// RemoteCode launched from a terminal has no launchd exit line; if its pid
    /// is later reused by another launchd job, that job's exit is not ours.
    func testIgnoresTheSamePidUnderAnotherLaunchdLabel() {
        let foreign = """
        2026-10-05 19:37:03.385 Df launchd[1:1bf2efa] [gui/501/com.apple.xpc.someservice [60220]:] exited due to SIGKILL | sent by launchd
        2026-10-05 19:37:04.385 Df launchd[1:1bf2efa] [gui/501/application.io.remotecode.desktop.debug.1.2 [60220]:] exited due to exit(0), ran for 5ms
        2026-10-05 19:37:05.385 Df launchd[1:1bf2efa] [system/io.remotecode.RunAsUserHelper [60220]:] exited due to exit(0), ran for 5ms
        """
        XCTAssertNil(
            PreviousRunExitStatus.launchdExitReason(inLogOutput: foreign, pid: 60220, bundleIdentifier: bundleId),
            "a reused pid under another label (including the debug channel) must not be reported as this app's exit"
        )
        XCTAssertEqual(
            PreviousRunExitStatus.launchdExitReason(
                inLogOutput: foreign + "\n" + launchdOutput, pid: 60220, bundleIdentifier: bundleId
            ),
            "exited due to exit(1), ran for 35005804ms"
        )
        XCTAssertEqual(
            PreviousRunExitStatus.launchdExitReason(
                inLogOutput: foreign, pid: 60220, bundleIdentifier: "io.remotecode.desktop.debug"
            ),
            "exited due to exit(0), ran for 5ms",
            "the real LaunchServices label is application.<bundle id>.<number>.<number>"
        )
    }

    func testRecordsLaunchdReasonFromALogQueryAroundTheLastHeartbeat() {
        let lastAlive = Date(timeIntervalSince1970: 1_791_000_000)
        var queried: [String] = []
        let line = PreviousRunExitStatus.lifecycleLine(
            pid: 60220, lastAlive: lastAlive, bundleIdentifier: bundleId, now: lastAlive.addingTimeInterval(86_400)
        ) { arguments, _ in
            queried = arguments
            return self.launchdOutput
        }

        XCTAssertEqual(line, "previous_run_exit pid=60220 launchd=\"exited due to exit(1), ran for 35005804ms\"")
        XCTAssertTrue(queried.contains { $0.contains("subsystem ENDSWITH \"[60220]\"") }, "query must target the dead pid")
        XCTAssertTrue(
            queried.contains { $0.contains("subsystem CONTAINS \"/application.io.remotecode.desktop.\"") },
            "query must target this app's launchd label, not any job with the pid"
        )
        let start = queried[queried.firstIndex(of: "--start")! + 1]
        let end = queried[queried.firstIndex(of: "--end")! + 1]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(formatter.string(from: lastAlive.addingTimeInterval(-5)), start)
        XCTAssertEqual(
            formatter.string(from: lastAlive.addingTimeInterval(3 * 60 * 60)), end,
            "a hang stops heartbeats, so the window must reach hours past the last one"
        )
    }

    func testUnknownWhenTheQueryFailsOrFindsNothing() {
        let lastAlive = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(
            PreviousRunExitStatus.lifecycleLine(pid: 42, lastAlive: lastAlive, bundleIdentifier: bundleId) { _, _ in nil },
            "previous_run_exit pid=42 launchd=unknown",
            "a timed-out query must still leave a line, not silence"
        )
        XCTAssertEqual(
            PreviousRunExitStatus.lifecycleLine(pid: 42, lastAlive: lastAlive, bundleIdentifier: bundleId) { _, _ in "Timestamp\n" },
            "previous_run_exit pid=42 launchd=unknown"
        )
        var ran = false
        XCTAssertEqual(
            PreviousRunExitStatus.lifecycleLine(pid: 42, lastAlive: nil, bundleIdentifier: bundleId) { _, _ in ran = true; return nil },
            "previous_run_exit pid=42 launchd=unknown"
        )
        XCTAssertFalse(ran, "without a last sign of life there is no window to search")
        XCTAssertEqual(
            PreviousRunExitStatus.lifecycleLine(pid: 42, lastAlive: lastAlive, bundleIdentifier: nil) { _, _ in ran = true; return nil },
            "previous_run_exit pid=42 launchd=unknown"
        )
        XCTAssertFalse(ran, "an unbundled build has no launchd label to match, so it must not guess")
    }

    func testHeartbeatMovesTheMarkersLastAliveSoTheNextLaunchSearchesTheRightWindow() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Lifecycle-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let recorder = AppLifecycleRecorder(directory: dir)
        recorder.beginRun()
        let pid = ProcessInfo.processInfo.processIdentifier
        let marker = dir.appendingPathComponent("running.\(pid).marker")
        let launchTime = Date(timeIntervalSinceNow: -3_600)
        try FileManager.default.setAttributes([.modificationDate: launchTime], ofItemAtPath: marker.path)

        recorder.recordHeartbeat(reason: "periodic")

        let touched = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(touched.timeIntervalSince(launchTime), 3_000, "a heartbeat must refresh the last sign of life")
    }

    func testStaleMarkerRecordCarriesPidAndLastAlive() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Lifecycle-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // pid 99999 with a start time that cannot match any live process.
        let marker = dir.appendingPathComponent("running.99999.marker")
        try Data("pid=99999 startedAt=2026-10-05T12:00:00Z procStart=1.000000".utf8).write(to: marker)
        let lastAlive = Date(timeIntervalSince1970: 1_791_000_000)
        try FileManager.default.setAttributes([.modificationDate: lastAlive], ofItemAtPath: marker.path)

        let records = AppLifecycleRecorder(directory: dir).consumeStaleRunMarkerRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.pid, 99999)
        XCTAssertEqual(records.first?.lastAlive, lastAlive)
        XCTAssertEqual(records.first?.contents, "pid=99999 startedAt=2026-10-05T12:00:00Z procStart=1.000000")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a consumed marker must not be reported twice")
    }
}
