import XCTest
import CryptoKit
import CoreModel
@testable import AppShell

/// The agent kit is what the Mac relies on to start, find and stop an in-guest
/// agent run. Most tests pin what the Mac side controls: what lands in
/// guest-tools, with which modes, how it is replaced, and that malformed input
/// is refused. The run-time behaviour (tagging, session/descendant kill, lease
/// reaper) needs Linux /proc: `test_live_*` proves it in a throwaway container
/// when RC_LIVE_DOCKER=1.
final class BotGuestAgentKitTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-kit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private var tools: URL { BotComputerGuestSpec.guestToolsURL(appSupport: support) }

    private func kitSource() throws -> URL {
        try XCTUnwrap(AppShellResourceBundle.guestAgentKitURL(), "GuestAgentKit resource must resolve")
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func test_materialize_copiesEveryKitFileWithGuestModes_andKeepsTheDistillCache() throws {
        // The distill cache shares guest-tools; materializing must not wipe a 220 MB download.
        let cached = tools.appendingPathComponent("distill/2.0.31/distill-linux-aarch64")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: cached)

        try BotGuestAgentKit.materialize(appSupport: support)

        let source = try kitSource()
        for file in BotGuestAgentKit.files {
            let target = tools.appendingPathComponent(file.path)
            XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source.appendingPathComponent(file.path)), file.path)
            // The read-only bind keeps host modes: the guest can only exec what is 0755 here.
            XCTAssertEqual(try mode(target), file.mode, file.path)
        }
        XCTAssertEqual(try Data(contentsOf: cached), Data("binary".utf8))
    }

    func test_materialize_leavesCurrentFilesAlone_andReplacesStaleOnesByRename() throws {
        try BotGuestAgentKit.materialize(appSupport: support)
        let killAgent = tools.appendingPathComponent("bin/kill-agent")
        let unchanged = try inode(killAgent)
        try BotGuestAgentKit.materialize(appSupport: support)
        XCTAssertEqual(try inode(killAgent), unchanged, "a current file is not rewritten on every provision")

        // A kit from an older app version, or a mode someone changed.
        try Data("#!/bin/bash\necho old\n".utf8).write(to: killAgent)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: killAgent.path)
        let stale = try inode(killAgent)
        try BotGuestAgentKit.materialize(appSupport: support)

        XCTAssertEqual(try Data(contentsOf: killAgent), try Data(contentsOf: try kitSource().appendingPathComponent("bin/kill-agent")))
        XCTAssertEqual(try mode(killAgent), 0o755)
        // bash reads a script while it runs (the lease reaper loops in kill-agent);
        // rewriting it in place would corrupt a live reaper, a rename does not.
        XCTAssertNotEqual(try inode(killAgent), stale, "replaced by rename, never rewritten in place")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: killAgent.deletingLastPathComponent().path)
        XCTAssertEqual(Set(leftovers), ["kill-agent", "run-agent"], "no temporary files left behind")
    }

    func test_materialize_failsLoudWhenTheKitIsMissing() {
        XCTAssertThrowsError(try BotGuestAgentKit.materialize(appSupport: support, source: nil)) { error in
            XCTAssertEqual(error as? BotGuestAgentKit.Failure, .missingKit)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.appendingPathComponent("bin").path))
    }

    func test_bundledKit_holdsExactlyTheMaterializedFiles() throws {
        // A file added to the resource but not to `files` would never reach the guest;
        // the linux-use Chrome extension must not ship in the guest kit at all.
        let source = try kitSource()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]))
        var found = Set<String>()
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            found.insert(String(url.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1)))
        }
        XCTAssertEqual(found, Set(BotGuestAgentKit.files.map(\.path)))
    }

    func test_vendoredLinuxUse_isTheRecordedUpstreamCommitWithOnlyTheRecordedPatch() throws {
        // Any edit to the vendored server must be recorded in UPSTREAM, so a
        // later re-vendor knows what to carry over.
        let source = try kitSource()
        let upstream = try String(contentsOf: source.appendingPathComponent("linux-use/UPSTREAM"), encoding: .utf8)
        XCTAssertTrue(upstream.contains("release v1.4.0, commit dba0828af6ae6edc0cc19168079a581895757a47"))
        XCTAssertTrue(upstream.contains("upstream server.py sha256 00298bbe19ef18d1f1273391aa6500a2f29ddb3d2990ea35d0f794b289ee196a"))
        // server.py imports its sibling modules from its own folder; a sibling from another
        // release would break it in the guest, so each one is pinned to the recorded bytes.
        for name in ["server.py", "cua_native.py", "atspi_tree.py", "subtask.py"] {
            let file = try Data(contentsOf: source.appendingPathComponent("linux-use/\(name)"))
            let digest = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(upstream.contains("\n\(name) sha256 \(digest)\n"), "\(name) changed without updating UPSTREAM")
            XCTAssertTrue(BotGuestAgentKit.files.contains { $0.path == "linux-use/\(name)" }, "\(name) is not copied into the guest")
        }
    }

    func test_vendoredLinuxUse_offersTheGuestAgentOnlyToolsThatCanWork() throws {
        // The guest has no Chrome extension and no decision-model key: an agent
        // offered browser_*, page, jev_decide or run_subtask spends turns on tools
        // that can only fail. Browsing goes through the guest's Playwright MCP instead.
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("\(python) is not available to run the vendored linux-use server")
        }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_open","arguments":{"url":"https://example.com"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"jev_decide","arguments":{"goal":"x"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"run_subtask","arguments":{"goal":"x"}}}"#,
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        // Not -I: isolated mode drops the script's folder from sys.path, and server.py imports
        // cua_native, atspi_tree and subtask from there, as the guest's `python3 server.py` does.
        process.arguments = [try kitSource().appendingPathComponent("linux-use/server.py").path]
        // No __pycache__ in the app's resource folder: the kit copies exactly `files`.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": support.path, "PYTHONDONTWRITEBYTECODE": "1"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        process.waitUntilExit()
        guard lines.count == requests.count else {
            throw XCTSkip("\(python) did not run the server (exit \(process.terminationStatus)); a Command Line Tools stub?")
        }
        var replies: [Int: [String: Any]] = [:]
        for line in lines {
            let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            replies[try XCTUnwrap(reply["id"] as? Int)] = reply
        }

        let tools = try XCTUnwrap((replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["screenshot", "list_windows", "click", "type_text", "press_key", "doctor",
                                            "get_ui_tree", "click_element", "set_value", "run_steps"]), "\(names)")
        XCTAssertTrue(names.filter { $0.hasPrefix("browser_") || ["page", "jev_decide", "run_subtask"].contains($0) }.isEmpty, "\(names)")
        for (id, tool) in [(3, "browser_open"), (4, "jev_decide"), (5, "run_subtask")] {
            let error = replies[id]?["error"] as? [String: Any]
            XCTAssertEqual(error?["message"] as? String, "unknown tool: \(tool)")
        }
        let instructions = try XCTUnwrap((replies[1]?["result"] as? [String: Any])?["instructions"] as? String)
        for absent in ["Chrome", "Jev", "browser_", "SKILL.md"] {
            XCTAssertFalse(instructions.contains(absent), "initialize instructions still mention \(absent)")
        }
    }

    func test_scripts_useTheSpecPathsTheMacWrites() throws {
        // The Mac renews leases where the reaper reads them; a mismatch reaps every run after 45 s.
        let source = try kitSource()
        let killAgent = try String(contentsOf: source.appendingPathComponent("bin/kill-agent"), encoding: .utf8)
        XCTAssertTrue(killAgent.contains("lease_dir=\(BotComputerGuestSpec.agentLeaseDirectory)\n"))
        XCTAssertTrue(BotComputerGuestSpec.runAgentPath.hasPrefix(BotComputerGuestSpec.agentKitMountPoint + "/"))
        XCTAssertEqual(BotComputerGuestSpec.runAgentPath, "/opt/remotecode-agent/bin/run-agent")
        XCTAssertEqual(BotComputerGuestSpec.killAgentPath, "/opt/remotecode-agent/bin/kill-agent")
        XCTAssertEqual(BotComputerGuestSpec.linuxUseServerPath, "/opt/remotecode-agent/linux-use/server.py")
    }

    // MARK: - Input validation (runs the real scripts; refused before any Linux-only step)

    private func run(
        _ script: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        // Each script's own shebang interpreter (sh for run-agent, bash for kill-agent).
        process.executableURL = URL(fileURLWithPath: script == "run-agent" ? "/bin/sh" : "/bin/bash")
        process.arguments = [try kitSource().appendingPathComponent("bin/\(script)").path] + arguments
        if let environment { process.environment = environment }
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            XCTFail("\(script) \(arguments) still running after \(timeout) s")
            exited.wait()
        }
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, message)
    }

    func test_runAgent_failsInsteadOfReexecingForeverWhenItCannotLeadASession() throws {
        // run-agent re-execs under setsid when it does not lead a session. An
        // image without ps (procps), or a setsid that cannot help, used to make
        // every level re-exec again: thousands of processes in the shared VM
        // and the agent never ran. It must re-exec at most once, then fail.
        // macOS has no /proc, so run-agent never sees itself as a leader here.
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let runID = AgentRunID().description

        // No ps and no setsid on PATH: the re-exec itself fails.
        let missing = try run("run-agent", [runID, "--", "/bin/echo", "AGENT-RAN"], environment: ["PATH": bin.path], timeout: 5)
        XCTAssertNotEqual(missing.status, 0)

        // A setsid that runs the command without a new session (the old loop).
        let fakeSetsid = bin.appendingPathComponent("setsid")
        try Data("#!/bin/sh\nshift\nexec \"$@\"\n".utf8).write(to: fakeSetsid)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSetsid.path)
        let looped = try run("run-agent", [runID, "--", "/bin/echo", "AGENT-RAN"], environment: ["PATH": bin.path], timeout: 5)
        XCTAssertEqual(looped.status, 71)
        XCTAssertTrue(looped.stderr.contains("cannot make the run a session leader"), looped.stderr)
    }

    func test_runAgent_refusesMalformedRunIDsAndArguments() throws {
        // The run id names the pid file and the lease path: it must never be a path.
        let valid = AgentRunID().description
        let refused: [[String]] = [
            [],
            ["", "--", "true"],
            ["../../../../etc/passwd-0000000000000", "--", "true"],
            [String(valid.dropLast()), "--", "true"],
            [String(valid.dropLast()) + "/", "--", "true"],
            [valid, "true"],
            [valid, "--"],
        ]
        for arguments in refused {
            let result = try run("run-agent", arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.contains("usage: run-agent"), "\(arguments)")
        }
    }

    func test_killAgent_refusesMalformedArguments() throws {
        let valid = AgentRunID().description
        let refused: [[String]] = [
            [],
            ["../../tmp/x-00000000000000000000000000000"],
            [valid, valid],
            ["--all", valid],
            ["--reap"],
            ["--reap", "not-a-run"],
        ]
        for arguments in refused {
            let result = try run("kill-agent", arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.contains("usage: kill-agent"), "\(arguments)")
        }
    }

    // MARK: - Live guest behaviour (RC_LIVE_DOCKER=1; throwaway rc-plana-spike-* container)

    private struct Docker {
        let executable: String
        let container: String

        @discardableResult
        func callAsFunction(_ arguments: [String]) throws -> (status: Int32, stdout: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }

        /// `docker exec` as the guest user every run and kill-agent runs as.
        @discardableResult
        func guest(_ command: [String], env: [String: String] = [:], detached: Bool = false) throws -> (status: Int32, stdout: String) {
            var arguments = ["exec"] + (detached ? ["-d"] : []) + ["-u", BotComputerGuestSpec.agentUser]
            for (key, value) in env.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
            return try self(arguments + [container] + command)
        }

        /// Whether any process still carries the run's tag. Every tagged process
        /// belongs to the guest user, so this read is never permission-blind.
        func runIsAlive(_ run: String) throws -> Bool {
            let found = try guest(["sh", "-c", "grep -lsa 'RC_GUEST_RUN_ID=\(run)' /proc/[0-9]*/environ"]).stdout
            return !found.isEmpty
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return try condition()
    }

    func test_live_killAgentAndLeaseReaper_endExactlyTheRunAndNothingElse() throws {
        // WHY: Stop, quit and a crashed Mac all rely on these scripts to end an
        // agent that outlives its `docker exec` client. A missed process keeps
        // spending the user's account inside the VM; a wrong one kills the
        // bot's desktop.
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 to run the agent kit in a throwaway guest container")
        }
        let executable: String
        do {
            executable = try BotComputerDockerResolver.shared.resolveHealthyExecutable()
        } catch {
            throw XCTSkip("docker unavailable: \(error)")
        }
        let image = BotComputerGuestSpec.imageTag
        let docker = Docker(executable: executable, container: "rc-plana-spike-kit-\(UUID().uuidString.prefix(8).lowercased())")
        guard try docker(["image", "inspect", image]).status == 0 else {
            throw XCTSkip("\(image) is not built on this Docker host")
        }
        try BotGuestAgentKit.materialize(appSupport: support)
        let started = try docker([
            // --init like every bot container: it reaps the orphaned reapers.
            "run", "-d", "--rm", "--init", "--name", docker.container, "--entrypoint", "sleep",
            "-v", "\(tools.path):\(BotComputerGuestSpec.agentKitMountPoint):ro", image, "infinity",
        ])
        defer { _ = try? docker(["rm", "-f", docker.container]) }
        guard started.status == 0 else { return XCTFail("could not start \(docker.container) from \(image)") }

        let leases = BotComputerGuestSpec.agentLeaseDirectory
        let runAgent = BotComputerGuestSpec.runAgentPath
        let killAgent = BotComputerGuestSpec.killAgentPath
        let fast = ["RC_AGENT_LEASE_MAX_AGE": "2", "RC_AGENT_REAP_INTERVAL": "1"]
        // The test bypasses the image entrypoint that normally prepares the home.
        // Fail setup explicitly rather than silently running the renewer in a root-owned directory.
        let setup = try docker(["exec", "-u", "0", docker.container, "sh", "-c",
            "mkdir -p \(leases) && chown remotecode:remotecode \(leases)"])
        XCTAssertEqual(setup.status, 0, "the guest must be able to renew its lease")

        // 1. Lease reaper. The Mac never renews `stale`. The `renewed`
        //    counter advances even when the bind mount's mtime stays fixed in 1970:
        //    the renewal itself must count, not cached filesystem metadata
        //    or its age against the guest clock.
        let stale = AgentRunID().description
        let renewed = AgentRunID().description
        let blocked = AgentRunID().description
        try docker.guest(["mkfifo", "\(leases)/\(blocked).lease"])
        try docker.guest(["sh", "-c", "i=0; while :; do i=$((i+1)); printf '%s\\n' $i > \(leases)/\(renewed).tmp; touch -d @1 \(leases)/\(renewed).tmp; mv \(leases)/\(renewed).tmp \(leases)/\(renewed).lease; sleep 0.3; done"], detached: true)
        try docker.guest([runAgent, stale, "--", "sleep", "300"], env: fast, detached: true)
        try docker.guest([runAgent, renewed, "--", "sleep", "300"], env: fast, detached: true)
        try docker.guest([runAgent, blocked, "--", "sleep", "300"], env: fast, detached: true)
        XCTAssertTrue(try waitUntil(5) {
            try docker.runIsAlive(stale) && docker.runIsAlive(renewed) && docker.runIsAlive(blocked)
        }, "runs never started")
        XCTAssertTrue(try waitUntil(15) { try !docker.runIsAlive(stale) }, "a run whose lease is never renewed must be reaped")
        XCTAssertTrue(try waitUntil(15) { try !docker.runIsAlive(blocked) }, "a FIFO must not prevent orphan cleanup")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(try docker.runIsAlive(renewed), "a run whose lease keeps changing must survive")

        // 2. Stop is idempotent: the second kill finds nothing and still succeeds.
        XCTAssertEqual(try docker.guest([killAgent, renewed]).status, 0)
        XCTAssertFalse(try docker.runIsAlive(renewed))
        XCTAssertEqual(try docker.guest([killAgent, renewed]).status, 0)

        // 3. A run that ignores TERM is ended by KILL.
        let stubborn = AgentRunID().description
        try docker.guest([runAgent, stubborn, "--", "bash", "-c", "trap '' TERM; while :; do sleep 1; done"], detached: true)
        XCTAssertTrue(try waitUntil(5) { try docker.runIsAlive(stubborn) })
        let killStarted = Date()
        XCTAssertEqual(try docker.guest([killAgent, stubborn]).status, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(killStarted), 1, "TERM is given 1 s before KILL")
        XCTAssertFalse(try docker.runIsAlive(stubborn))

        // 4. The launch sweep ends every run but not the desktop's untagged processes.
        let swept = AgentRunID().description
        try docker.guest(["sleep", "301"], detached: true)
        try docker.guest([runAgent, swept, "--", "sleep", "302"], detached: true)
        XCTAssertTrue(try waitUntil(5) { try docker.runIsAlive(swept) })
        XCTAssertEqual(try docker.guest([killAgent, "--all"]).status, 0)
        XCTAssertFalse(try docker.runIsAlive(swept))
        // The bracket keeps this probe's own command line from matching.
        let desktop = try docker.guest(["sh", "-c", "for f in /proc/[0-9]*/cmdline; do tr '\\0' ' ' < $f; echo; done | grep -c '^sleep 30[1] '"]).stdout
        XCTAssertEqual(desktop.trimmingCharacters(in: .whitespacesAndNewlines), "1", "an untagged process must survive kill-agent --all")
    }
}
