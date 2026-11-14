import XCTest
import Darwin
@testable import Surfaces

/// GhosttyKit's embedded Sentry/Breakpad takes over the task exception ports and
/// SIGABRT, then turns a native crash into a silent `_exit(exception_type)`: the
/// app "closes by itself" with no `.ips` report (pid 60220 exited with exit(1)
/// after 9.7 h and left nothing to diagnose). Restoring the snapshot taken
/// before Ghostty starts must hand every crash handler back to macOS.
final class NativeCrashHandlerSnapshotTests: XCTestCase {
    func testRestoreUndoesAReporterThatTookOverExceptionPortsAndSIGABRT() throws {
        let before = NativeCrashHandlerSnapshot.capture()
        defer { before.restore() }

        // What Breakpad does: its own port for the crash exceptions, its own SIGABRT handler.
        var port = mach_port_t()
        XCTAssertEqual(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port), KERN_SUCCESS)
        defer { mach_port_destruct(mach_task_self_, port, -1, 0) }
        XCTAssertEqual(
            mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)),
            KERN_SUCCESS
        )
        XCTAssertEqual(
            task_set_exception_ports(
                mach_task_self_, exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BREAKPOINT),
                port, EXCEPTION_DEFAULT, THREAD_STATE_NONE
            ),
            KERN_SUCCESS
        )
        var reporter = sigaction()
        reporter.__sigaction_u.__sa_handler = { _ in }
        XCTAssertEqual(sigaction(SIGABRT, &reporter, nil), 0)

        let taken = NativeCrashHandlerSnapshot.capture()
        XCTAssertNotEqual(taken.exceptionPorts, before.exceptionPorts, "the snapshot must see a replaced exception port")
        XCTAssertNotEqual(taken.signals, before.signals, "the snapshot must see a replaced SIGABRT handler")

        before.restore()

        let after = NativeCrashHandlerSnapshot.capture()
        XCTAssertEqual(after, before, "the host's crash handlers must be back exactly as they were")
        XCTAssertFalse(after.exceptionPorts.contains { $0.port == port }, "the reporter's port must not survive")
    }

    /// GhosttyKit starts its reporter on a thread of its own. When that thread
    /// finishes after `end()`, the handlers are taken for the life of the
    /// process and every child process inherits the reporter's exception port:
    /// MacCode pid 1278 exited with exit(1) the moment a `cargo test` binary,
    /// started by an agent an hour after launch, overflowed its stack. An
    /// install that arrives late must still be undone.
    func testGuardUndoesAReporterThatInstallsAfterInitReturned() throws {
        let before = NativeCrashHandlerSnapshot.capture()
        defer { before.restore() }

        let crashGuard = GhosttyCrashHandlerGuard.begin()
        let watch = crashGuard.end(watchingFor: 60, every: 0.002)
        defer {
            watch.cancel()
            GhosttyCrashHandlerGuard.watchQueue.sync {}
        }
        XCTAssertEqual(
            GhosttyCrashHandlerGuard.lastReport,
            GhosttyCrashHandlerGuard.Report(changedDuringInit: false, restored: true),
            "nothing was installed yet when init returned"
        )

        // The reporter's thread finishing late: its own port, its own SIGABRT handler.
        var port = mach_port_t()
        XCTAssertEqual(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port), KERN_SUCCESS)
        defer { mach_port_destruct(mach_task_self_, port, -1, 0) }
        XCTAssertEqual(
            mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)),
            KERN_SUCCESS
        )
        var reporter = sigaction()
        reporter.__sigaction_u.__sa_handler = { _ in }
        XCTAssertEqual(sigaction(SIGABRT, &reporter, nil), 0)
        XCTAssertEqual(
            task_set_exception_ports(
                mach_task_self_, exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BREAKPOINT),
                port, EXCEPTION_DEFAULT, THREAD_STATE_NONE
            ),
            KERN_SUCCESS
        )

        let deadline = Date().addingTimeInterval(20)
        while NativeCrashHandlerSnapshot.capture() != before, Date() < deadline {
            usleep(1_000)
        }
        GhosttyCrashHandlerGuard.watchQueue.sync {}

        let after = NativeCrashHandlerSnapshot.capture()
        XCTAssertEqual(after, before, "a reporter that installs after init returned must still be undone")
        XCTAssertFalse(after.exceptionPorts.contains { $0.port == port }, "children must not inherit the reporter's port")
        XCTAssertGreaterThanOrEqual(GhosttyCrashHandlerGuard.lastReport?.lateRestores ?? 0, 1)
    }

    /// Once the watch is over, the guard must leave the crash handlers alone.
    func testGuardStopsRestoringWhenTheWatchEnds() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1",
            "the real runtime's own watch may still be restoring in this process"
        )
        let before = NativeCrashHandlerSnapshot.capture()
        defer { before.restore() }

        let watch = GhosttyCrashHandlerGuard.begin().end(watchingFor: 0.05, every: 0.002)
        let deadline = Date().addingTimeInterval(20)
        while !watch.isCancelled, Date() < deadline {
            usleep(1_000)
        }
        XCTAssertTrue(watch.isCancelled, "the watch must end by itself")
        GhosttyCrashHandlerGuard.watchQueue.sync {}

        var later = sigaction()
        later.__sigaction_u.__sa_handler = { _ in }
        XCTAssertEqual(sigaction(SIGABRT, &later, nil), 0)
        usleep(50_000)
        GhosttyCrashHandlerGuard.watchQueue.sync {}

        XCTAssertNotEqual(NativeCrashHandlerSnapshot.capture().signals, before.signals, "a handler installed after the watch must be kept")
    }

    /// GhosttyKit's Breakpad serves its exception port with libsystem's
    /// exc_server, which finds `catch_exception_raise` through dlsym and ends
    /// the process with exit(1) when it is missing. Nothing references the
    /// function statically, so a release link dead-strips it unless it is made
    /// a root; the packaged binary must be refused without it.
    func testReleaseLinkKeepsBreakpadsExceptionCatcher() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(
            manifest.contains(#".unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_catch_exception_raise"]"#),
            "the Surfaces target must root catch_exception_raise against dead-stripping"
        )
        let packager = try String(contentsOf: root.appendingPathComponent("scripts/package-app.sh"), encoding: .utf8)
        XCTAssertTrue(
            packager.contains(#"if ! nm -gU "$BIN" | grep ' _catch_exception_raise$' >/dev/null; then"#),
            "packaging must refuse a binary that does not export catch_exception_raise"
        )
    }

    /// Runs by default (the real-GhosttyKit test below is opt-in): the runtime
    /// must take the snapshot before ghostty_init and restore it on every path.
    func testRuntimeInitWrapsGhosttyInitInTheCrashHandlerGuard() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/GhosttyTerminalView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let initialize = try XCTUnwrap(source.range(of: "private func initialize() {"))
        let body = source[initialize.upperBound...]
        let begin = try XCTUnwrap(body.range(of: "let crashHandlerGuard = GhosttyCrashHandlerGuard.begin()"))
        let end = try XCTUnwrap(body.range(of: "defer { crashHandlerGuard.end() }"))
        let ghosttyInit = try XCTUnwrap(body.range(of: "ghostty_init("))
        XCTAssertLessThan(begin.lowerBound, ghosttyInit.lowerBound, "the snapshot must be taken before Ghostty installs its reporter")
        XCTAssertLessThan(end.lowerBound, ghosttyInit.lowerBound, "the restore must be deferred so early returns restore too")
        XCTAssertEqual(source.components(separatedBy: "ghostty_init(").count, 2, "ghostty_init must have exactly one, guarded, call site")
    }

    /// The real GhosttyKit: proves it replaces the crash handlers (the premise
    /// of the fix), while initializing or later from its own thread, and that
    /// the runtime puts them back either way.
    @MainActor
    func testGhosttyInitReplacesCrashHandlersAndTheRuntimeRestoresThem() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 to initialize the real GhosttyKit")
        }
        let before = NativeCrashHandlerSnapshot.capture()
        _ = GhosttyTerminalView.resolvedANSIThemeColors()

        var report = try XCTUnwrap(GhosttyCrashHandlerGuard.lastReport, "the runtime must initialize through the guard")
        XCTAssertTrue(report.restored, "the host's crash handlers must be restored after Ghostty starts")
        let deadline = Date().addingTimeInterval(10)
        while !report.changedDuringInit, report.lateRestores == 0, Date() < deadline {
            usleep(10_000)
            report = try XCTUnwrap(GhosttyCrashHandlerGuard.lastReport)
        }
        XCTAssertTrue(
            report.changedDuringInit || report.lateRestores > 0,
            "GhosttyKit's crash reporter was expected to install handlers"
        )
        GhosttyCrashHandlerGuard.watchQueue.sync {}
        XCTAssertEqual(NativeCrashHandlerSnapshot.capture(), before, "the host's crash handlers must be back after Ghostty's reporter started")
    }
}
