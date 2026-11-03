import XCTest
@testable import CoreModel

final class BotComputerDockerClientTests: XCTestCase {
    func test_createKeepsTheBotDesktopRestartingAcrossDockerRestarts() throws {
        // WHY: the bot VM is always on; without this policy a Docker or Mac
        // restart leaves the desktop stopped until the next run.
        var captured: [String] = []
        let cli = BotComputerDockerCLI { args in
            captured = args
            return Data("container-id\n".utf8)
        }
        let options = BotComputerContainerCreateOptions(
            name: "remotecode-bot-restart",
            image: "remotecode-computer:test",
            labels: [:],
            environment: [:],
            binds: [],
            hostIP: "127.0.0.1",
            hostPort: 0,
            containerPort: 6080,
            shmSize: 1_024,
            network: nil
        )

        _ = try cli.create(options: options)

        let flag = try XCTUnwrap(captured.firstIndex(of: "--restart"))
        XCTAssertEqual(captured[flag + 1], "unless-stopped")
        XCTAssertEqual(captured.first, "create")
        XCTAssertEqual(captured.last, "remotecode-computer:test")
    }

    func test_networkExistsRequiresReadableExactCensus() throws {
        let present = BotComputerDockerCLI { args in
            XCTAssertEqual(args, ["network", "ls", "-q", "--filter", "name=^context-network$"])
            return Data("network-id\n".utf8)
        }
        XCTAssertTrue(try present.networkExists(name: "context-network"))
        XCTAssertFalse(try BotComputerDockerCLI { _ in Data() }.networkExists(name: "context-network"))
        XCTAssertThrowsError(try BotComputerDockerCLI { _ in Data([0xff]) }.networkExists(name: "context-network"))
    }

    func test_containerExistsUsesAnExactAnchoredDockerCensus() throws {
        // WHY: cleanup may forgive a failed rm only after Docker proves the
        // exact canonical container is absent; prefix matches are not proof.
        var calls: [[String]] = []
        let present = BotComputerDockerCLI { args in
            calls.append(args)
            return Data("container-id\n".utf8)
        }

        XCTAssertTrue(try present.containerExists(name: "remotecode-bot-exact"))
        XCTAssertEqual(calls, [["ps", "-aq", "--filter", "name=^/remotecode-bot-exact$"]])

        let absent = BotComputerDockerCLI { _ in Data() }
        XCTAssertFalse(try absent.containerExists(name: "remotecode-bot-exact"))
        let unknown = BotComputerDockerCLI { _ in throw BotComputerDockerError.daemonUnavailable }
        XCTAssertThrowsError(try unknown.containerExists(name: "remotecode-bot-exact"))
        XCTAssertThrowsError(try BotComputerDockerCLI { _ in Data([0xff]) }
            .containerExists(name: "remotecode-bot-exact")) { error in
                XCTAssertEqual(error as? BotComputerDockerError, .provisioningFailed)
            }
    }

    func test_inspectRejectsMalformedRunningTokenWithOtherwiseValidOwnedFields() throws {
        let cli = BotComputerDockerCLI { _ in
            Data("unknown sha256:abc 36385 net-a, {\"remotecode.botId\":\"b\"}\n\"/owned/home\"\n".utf8)
        }
        XCTAssertThrowsError(try cli.inspect(name: "remotecode-bot-b")) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .provisioningFailed)
        }
    }

    func test_inspectAcceptsOnlyExplicitTrueOrFalseRunningTokens() throws {
        for (token, expected) in [("true", true), ("TRUE", true), ("false", false)] {
            let cli = BotComputerDockerCLI { _ in Data("\(token) sha256:abc 36385 net-a, {}\n\n".utf8) }
            XCTAssertEqual(try cli.inspect(name: "container").running, expected)
        }
        XCTAssertThrowsError(try BotComputerDockerCLI { _ in Data("unknown sha256:abc 0 net-a, {}\n\n".utf8) }.inspect(name: "container"))
    }

    func test_inspectRejectsInvalidUTF8() {
        XCTAssertThrowsError(try BotComputerDockerCLI { _ in Data([0xff]) }.inspect(name: "container")) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .provisioningFailed)
        }
    }

    func test_inspectReadsTheHomeBindSource_soAContainerOfAnotherAppIsToldApart() throws {
        // WHY: the launch sweep kills in-guest agents; the installed app and a
        // debug sandbox share one Docker daemon, and the guest-home bind (in
        // each app's own Application Support) is what proves a container is
        // this app's. The path holds spaces, so it rides JSON-quoted on its
        // own line without disturbing the fields before it.
        let home = "/Users/a/Library/Application Support/RemoteCode/bot-guests/b/home"
        var formats: [String] = []
        let cli = BotComputerDockerCLI { args in
            formats.append(args[2])
            return Data(("true sha256:abc 36385 net-a, {\"remotecode.botId\":\"b\"}\n\"\(home)\"\n").utf8)
        }
        let inspect = try cli.inspect(name: "remotecode-bot-b")
        XCTAssertEqual(inspect, BotComputerContainerInspect(
            running: true, imageID: "sha256:abc", hostPort: 36385, networkNames: ["net-a"],
            labels: ["remotecode.botId": "b"], homeSource: home
        ))
        XCTAssertTrue(formats.first?.contains("eq .Destination \"/home/remotecode\"") == true)

        let noHome = BotComputerDockerCLI { _ in Data("false sha256:abc 0  {}\n\n".utf8) }
        XCTAssertNil(try noHome.inspect(name: "x").homeSource, "a container without a home bind proves nothing")
    }

    func test_buildLabelsTheImageWithTheDigestOfTheRecipeItWasBuiltFrom() throws {
        // WHY: the app reuses a base image only when this label matches its own
        // recipe; an image from another recipe under the same tag and revision
        // must be told apart. Any recipe file edit must change the digest.
        let context = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: context) }
        for name in BotComputerGuestSpec.recipeFileNames {
            try Data(name.utf8).write(to: context.appendingPathComponent(name))
        }
        var calls: [[String]] = []
        let cli = BotComputerDockerCLI { args in
            calls.append(args)
            return Data()
        }

        try cli.build(context: context, tag: "remotecode/computer:test")

        let digest = BotComputerGuestSpec.recipeDigest(context: context)
        XCTAssertEqual(calls, [[
            "build", "-t", "remotecode/computer:test",
            "--label", "\(BotComputerGuestSpec.recipeLabelKey)=\(BotComputerGuestSpec.recipeRevision)",
            "--label", "\(BotComputerGuestSpec.recipeDigestLabelKey)=\(digest)",
            context.path,
        ]])
        try Data("start.sh edited".utf8).write(to: context.appendingPathComponent("start.sh"))
        XCTAssertNotEqual(BotComputerGuestSpec.recipeDigest(context: context), digest)
        try FileManager.default.removeItem(at: context.appendingPathComponent("embed.html"))
        XCTAssertNotEqual(BotComputerGuestSpec.recipeDigest(context: context), digest)
    }

    func test_createPassesInitHostAliasAndTheReadOnlyAgentKitBind() throws {
        // WHY: create options only matter if they reach `docker create`; without
        // --init the agent's orphans are never reaped, without --add-host the
        // guest cannot name the host, and a writable kit bind would let the guest
        // rewrite the agent binary it runs.
        var calls: [[String]] = []
        let cli = BotComputerDockerCLI { args in
            calls.append(args)
            return Data("cid\n".utf8)
        }
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-docker-create-args")
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path,
            appSupport: support,
            viewerToken: String(repeating: "a", count: 32)
        )
        XCTAssertEqual(try cli.create(options: options), "cid")
        let args = try XCTUnwrap(calls.first)
        XCTAssertTrue(args.contains("--init"))
        let host = try XCTUnwrap(args.firstIndex(of: "--add-host"))
        XCTAssertEqual(args[host + 1], "host.docker.internal:host-gateway")
        XCTAssertTrue(args.contains("/tmp/rc-docker-create-args/guest-tools:/opt/remotecode-agent:ro"))
        XCTAssertEqual(args.last, BotComputerGuestSpec.imageTag, "the image stays the final argument")
    }

    func test_createCapsEachGuestsMemoryPidsAndCPU() throws {
        // WHY: unlimited guests share the Docker VM's memory; when one runs
        // out, the kernel kills processes in other bots' guests (seen: their
        // Chromium). Memory and swap must match so the cap is not bypassed.
        var calls: [[String]] = []
        let cli = BotComputerDockerCLI { args in
            calls.append(args)
            return Data("cid\n".utf8)
        }
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-docker-create-limits")
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path,
            appSupport: support,
            viewerToken: String(repeating: "a", count: 32)
        )
        _ = try cli.create(options: options)
        let args = try XCTUnwrap(calls.first)
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value("--memory"), "\(BotComputerGuestSpec.guestMemoryBytes)")
        XCTAssertEqual(value("--memory-swap"), "\(BotComputerGuestSpec.guestMemoryBytes)")
        XCTAssertEqual(value("--pids-limit"), "\(BotComputerGuestSpec.guestPidsLimit)")
        XCTAssertEqual(value("--cpus"), BotComputerGuestSpec.guestCPUs)
        XCTAssertGreaterThan(BotComputerGuestSpec.guestMemoryBytes, BotComputerGuestSpec.minimumShmBytes)
    }

    func test_runningManagedBotIDsReadsOnlyRunningManagedContainersBotLabels() throws {
        var calls: [[String]] = []
        let botID = BotID()
        let cli = BotComputerDockerCLI { args in
            calls.append(args)
            return Data("\(botID.value.uuidString.lowercased())\n\nnot-a-uuid\n".utf8)
        }
        XCTAssertEqual(try cli.runningManagedBotIDs(), [botID])
        let args = try XCTUnwrap(calls.first)
        XCTAssertTrue(args.contains("label=remotecode.managed=1"))
        XCTAssertTrue(args.contains("status=running"))
    }

    func test_unitTestsNeverReachTheRealDockerWithoutOptIn() throws {
        // WHY: tests that fell through to the real CLI left 165 running bot
        // desktops (each with Chromium) in the user's Docker VM.
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] != "1" else {
            throw XCTSkip("live Docker opt-in is set")
        }
        XCTAssertThrowsError(try BotComputerDockerCLI.defaultRun(["ps"])) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .cliMissing)
        }
    }

    func test_createPassesContextNetworkSecurityFlagsOnceAsSeparateArguments() throws {
        var calls: [[String]] = []
        let cli = BotComputerDockerCLI { args in calls.append(args); return Data() }
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-context-create-args")
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path,
            appSupport: support,
            viewerToken: String(repeating: "a", count: 32),
            contextualNetworkPolicy: true
        )
        _ = try cli.create(options: options)
        let args = try XCTUnwrap(calls.first)
        for pair in [["--cap-drop", "ALL"], ["--cap-add", "NET_ADMIN"], ["--security-opt", "no-new-privileges:true"], ["--tmpfs", "/run:rw,nosuid,nodev,noexec,mode=0755"], ["--label", "remotecode.context.network=private-egress-v1"], ["--env", "REMOTECODE_CONTEXT_NETWORK_POLICY=private-egress-v1"]] {
            XCTAssertEqual(zip(args, args.dropFirst()).filter { $0.0 == pair[0] && $0.1 == pair[1] }.count, 1, "\(pair) emitted once")
        }
        XCTAssertFalse(args.contains("--privileged"))
        XCTAssertFalse(args.contains(where: { $0 == "--user" || $0 == "-u" }))
    }

    func test_runProcessReturnsOutputLargerThanPipeCapacity() throws {
        // WHY: a real guest PNG is often larger than the OS pipe capacity, so
        // the runner must consume all bytes while the child is still writing.
        let expected = Data(repeating: 0x41, count: 1_048_576)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-docker-output-\(UUID().uuidString)")
        try expected.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try BotComputerDockerCLI.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [file.path]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.data, expected)
    }

    func test_runProcessFailsClosedWhenStdoutExceedsTheExactOutputLimit() throws {
        // WHY: docker exec can emit a guest screenshot far larger than expected.
        // Exact PNG bytes must never be truncated, but the app also must not
        // retain unbounded stdout while waiting for the subprocess to exit.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-docker-oversized-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(BotComputerDockerCLI.stdoutRetentionLimit + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(
            try BotComputerDockerCLI.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [file.path]
            )
        ) { error in
            XCTAssertEqual(
                error as? BotComputerDockerProcessError,
                .stdoutLimitExceeded
            )
        }
    }

    func test_runProcessDrainsOversizedNonExactBuildOutputWithoutRetainingIt() throws {
        // WHY: docker build logs are not consumed as an exact payload. They
        // must be drained without turning a verbose build into a provisioning
        // failure or an unbounded stdout allocation.
        let result = try BotComputerDockerCLI.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c \(BotComputerDockerCLI.stdoutRetentionLimit + 1) /dev/zero"],
            stdoutLimit: BotComputerDockerCLI.stdoutRetentionLimit,
            failOnStdoutLimit: false
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.data.isEmpty)
    }

    func test_defaultRunDrainsStdoutBeforeWaitingForExit() throws {
        // WHY: guest screenshots can exceed a pipe buffer. Waiting for Docker
        // before reading stdout deadlocks the child writer and freezes its caller.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CoreModel/BotComputerDockerClient.swift"),
            encoding: .utf8
        )
        let read = try XCTUnwrap(source.range(of: "stdout.fileHandleForReading.readData(ofLength:"))
        let wait = try XCTUnwrap(source.range(of: "process.waitUntilExit()"))

        XCTAssertLessThan(read.lowerBound, wait.lowerBound)
        XCTAssertTrue(source.contains("process.standardError = stderr"))
        XCTAssertFalse(
            source.contains("arguments: [\"docker\"] + args"),
            "GUI launches cannot assume /usr/bin/env docker is on PATH"
        )
    }

    func test_BotComputerDocker_strippedPATHStillListsAbsoluteDesktopCandidates() {
        let candidates = BotComputerDockerResolver.defaultCandidates(
            pathEnvironment: "",
            homeDirectory: NSHomeDirectory()
        )
        XCTAssertTrue(candidates.contains("/usr/local/bin/docker"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/docker"))
        XCTAssertTrue(candidates.contains("/Applications/Docker.app/Contents/Resources/bin/docker"))
        XCTAssertTrue(candidates.contains("/Applications/OrbStack.app/Contents/MacOS/xbin/docker"))
        XCTAssertTrue(candidates.contains { $0.hasSuffix("/.orbstack/bin/docker") })
        XCTAssertFalse(candidates.contains("/usr/bin/env"))
    }

    func test_BotComputerDocker_failingCandidateFallsThroughToHealthy() throws {
        let resolver = BotComputerDockerResolver(
            candidates: ["/tmp/remote-code-missing-docker", "/bin/echo"],
            probeTimeout: 1,
            probe: { candidate, _ in
                if candidate.contains("missing") { return .failed }
                return .healthy
            }
        )
        XCTAssertEqual(try resolver.resolveHealthyExecutable(), "/bin/echo")
        XCTAssertEqual(try resolver.resolveHealthyExecutable(), "/bin/echo")
    }

    func test_BotComputerDocker_hungCandidateIsKilledThenHealthyIsCached() throws {
        let hung = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-hung-docker-\(UUID().uuidString)")
        try """
        #!/bin/sh
        sleep 30
        """.write(to: hung, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)
        defer { try? FileManager.default.removeItem(at: hung) }

        var probed: [String] = []
        let resolver = BotComputerDockerResolver(
            candidates: [hung.path, "/bin/echo"],
            probeTimeout: 0.15,
            probe: { candidate, timeout in
                probed.append(candidate)
                if candidate == hung.path {
                    let result = try BotComputerDockerCLI.runProcess(
                        executableURL: hung,
                        arguments: ["info"],
                        timeout: timeout
                    )
                    XCTAssertTrue(result.timedOut)
                    return .timedOut
                }
                return .healthy
            }
        )
        XCTAssertEqual(try resolver.resolveHealthyExecutable(), "/bin/echo")
        XCTAssertEqual(probed, [hung.path, "/bin/echo"])
        XCTAssertEqual(try resolver.resolveHealthyExecutable(), "/bin/echo")
        XCTAssertEqual(probed.count, 2, "a healthy executable must be cached")
    }

    func test_BotComputerDocker_typedRecoveryCopyIsDistinct() {
        XCTAssertNotEqual(BotComputerDockerError.cliMissing.description, BotComputerDockerError.daemonUnavailable.description)
        XCTAssertNotEqual(BotComputerDockerError.daemonUnavailable.description, BotComputerDockerError.probeTimedOut.description)
        XCTAssertNotEqual(BotComputerDockerError.probeTimedOut.description, BotComputerDockerError.provisioningFailed.description)
        XCTAssertEqual(BotComputerDockerError.cliMissing.recovery.accessibilityAction, "Install Docker CLI")
        XCTAssertEqual(BotComputerDockerError.daemonUnavailable.recovery.accessibilityAction, "Start Docker")
        XCTAssertEqual(BotComputerDockerError.probeTimedOut.recovery.accessibilityAction, "Retry Docker check")
        XCTAssertEqual(BotComputerDockerError.provisioningFailed.recovery.accessibilityAction, "Retry starting Linux desktop")
    }

    func test_BotComputerDocker_networkPoolFailureRequiresTheExactDaemonMessage() throws {
        // WHY: only exhausted predefined subnets justify retrying with a small
        // explicit network. Permission or daemon errors must fail loud.
        let exhausted = Data(
            "Error response from daemon: all predefined address pools have been fully subnetted".utf8
        )
        XCTAssertEqual(
            BotComputerDockerCLI.failureError(
                for: ["network", "create", "remotecode-bot-1"],
                stderr: exhausted
            ),
            .networkAddressPoolExhausted
        )
        XCTAssertEqual(
            BotComputerDockerCLI.failureError(
                for: ["network", "create", "--subnet", "10.240.0.0/30", "remotecode-bot-1"],
                stderr: Data("invalid pool request: Pool overlaps with other one on this address space".utf8)
            ),
            .networkSubnetUnavailable
        )
        XCTAssertEqual(
            BotComputerDockerCLI.failureError(
                for: ["network", "create", "remotecode-bot-1"],
                stderr: Data("permission denied".utf8)
            ),
            .provisioningFailed
        )

        let result = try BotComputerDockerCLI.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'daemon detail' >&2; exit 1"]
        )
        XCTAssertEqual(String(decoding: result.errorData, as: UTF8.self), "daemon detail")
    }

    func test_BotComputerDocker_stderrRetentionIsBoundedWhileStillDrainingTheChild() throws {
        // WHY: Docker build can be noisy for minutes. Classification needs only
        // the final daemon detail, so stderr must be drained without retaining
        // an unbounded transcript in the app process.
        let phrase = Data(
            "all predefined address pools have been fully subnetted".utf8
        )
        var noisy = Data(repeating: 0x78, count: 2 * 1_024 * 1_024)
        noisy.append(phrase)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-docker-stderr-\(UUID().uuidString)")
        try noisy.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try BotComputerDockerCLI.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat \"$1\" >&2", "sh", file.path]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.errorData.count, BotComputerDockerCLI.stderrRetentionLimit)
        XCTAssertTrue(result.errorData.suffix(phrase.count).elementsEqual(phrase))
        XCTAssertEqual(
            BotComputerDockerCLI.failureError(
                for: ["network", "create", "remotecode-bot-1"],
                stderr: result.errorData
            ),
            .networkAddressPoolExhausted
        )
    }

    func test_BotComputerDocker_poolExhaustionCreatesAUniqueICCDisabledNetwork() throws {
        // WHY: pool exhaustion must recover without placing passwordless VNC
        // services on Docker's shared bridge. Overlapping /30 candidates may be
        // skipped, but the resulting network stays dedicated and ICC-disabled.
        let name = "remotecode-bot-00000000-0000-0000-0000-000000000001"
        let recorder = DockerNetworkRunRecorder(networkName: name)
        let exhausted = BotComputerDockerCLI { args in
            try recorder.run(args)
        }

        try exhausted.ensureNetwork(name: name)

        let explicit = recorder.calls.filter { $0.contains("--subnet") }
        XCTAssertEqual(explicit.count, 2)
        XCTAssertEqual(
            explicit.map { $0[$0.firstIndex(of: "--subnet")! + 1] },
            Array(BotComputerDockerCLI.isolatedNetworkSubnets(name: name).prefix(2))
        )
        XCTAssertTrue(explicit.allSatisfy {
            $0.contains("com.docker.network.bridge.enable_icc=false")
                && $0.contains("io.remotecode.bot.network=true")
                && $0.last == name
        })
    }

    func test_BotComputerDocker_explicitSubnetCandidatesAreStableUniqueSlash30s() {
        let name = "remotecode-bot-00000000-0000-0000-0000-000000000001"
        let first = BotComputerDockerCLI.isolatedNetworkSubnets(name: name)
        XCTAssertEqual(first, BotComputerDockerCLI.isolatedNetworkSubnets(name: name))
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(Set(first).count, first.count)
        XCTAssertTrue(first.allSatisfy { $0.hasPrefix("10.") && $0.hasSuffix("/30") })
    }

    func test_BotComputerDocker_nonPoolNetworkFailureDoesNotAttemptExplicitFallback() {
        // WHY: an explicit subnet is not a remedy for authorization or daemon
        // failures, and must not turn those errors into a weaker success path.

        let denied = BotComputerDockerCLI { _ in
            throw BotComputerDockerError.provisioningFailed
        }
        XCTAssertThrowsError(try denied.ensureNetwork(name: "remotecode-bot-2")) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .provisioningFailed)
        }
    }

    func test_liveCrossBotDesktopRequiresTheTargetBotsViewerToken() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 to exercise cross-Bot viewer authentication")
        }
        let suffix = UUID().uuidString.lowercased()
        let containerA = "remotecode-isolation-a-\(suffix)"
        let containerB = "remotecode-isolation-b-\(suffix)"
        let cli = BotComputerDockerCLI()
        let fixtureSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-cross-bot-\(suffix)", isDirectory: true)
        defer {
            try? cli.remove(name: containerA)
            try? cli.remove(name: containerB)
            if (try? cli.containerExists(name: containerA)) == false,
               (try? cli.containerExists(name: containerB)) == false {
                try? FileManager.default.removeItem(at: fixtureSupport)
            }
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recipe = repository.appendingPathComponent("Sources/AppShell/Resources/ComputerGuest")
        let digest = BotComputerGuestSpec.recipeDigest(context: recipe)
        let image = try XCTUnwrap(try cli.imageStates(tags: [BotComputerGuestSpec.imageTag])[BotComputerGuestSpec.imageTag])
        guard image.labels[BotComputerGuestSpec.recipeLabelKey] == BotComputerGuestSpec.recipeRevision,
              image.labels[BotComputerGuestSpec.recipeDigestLabelKey] == digest else {
            throw XCTSkip("the current shared guest image does not match this recipe revision and digest")
        }

        let botIDB = BotID()
        let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: fixtureSupport, botID: botIDB)
        try FileManager.default.createDirectory(at: guestHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestToolsURL(appSupport: fixtureSupport),
            withIntermediateDirectories: true
        )
        var optionsB = try BotComputerGuestSpec.containerCreateOptions(
            botID: botIDB,
            guestHome: guestHome.path,
            appSupport: fixtureSupport,
            viewerToken: String(repeating: "b", count: 32)
        )
        optionsB.name = containerB
        optionsB.network = "bridge"
        _ = try cli.create(options: optionsB)
        try cli.start(name: containerB)
        let tokenA = String(repeating: "a", count: 32)
        let tokenB = optionsB.environment["REMOTECODE_VIEWER_TOKEN"]!
        _ = try BotComputerDockerCLI.defaultRun([
            "run", "-d", "--name", containerA, "--network", "bridge",
            "--env", "REMOTECODE_VIEWER_TOKEN=\(tokenA)",
            "--entrypoint", "/bin/sleep", BotComputerGuestSpec.imageTag, "30",
        ])
        let inspectData = try BotComputerDockerCLI.defaultRun([
            "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} "
                + "{{(index (index .NetworkSettings.Ports \"6080/tcp\") 0).HostPort}}",
            containerB,
        ])
        let inspect = String(decoding: inspectData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        let serverIP = try XCTUnwrap(inspect.first)
        let hostPort = try XCTUnwrap(inspect.dropFirst().first)

        let rfbScript = """
            import base64, os, socket, struct, sys
            host, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
            path = '/websockify' + (('?token=' + token) if token else '')
            sock = socket.create_connection((host, port), timeout=3)
            key = base64.b64encode(os.urandom(16)).decode()
            request = (f'GET {path} HTTP/1.1\\r\\nHost: {host}:{port}\\r\\n'
                       'Upgrade: websocket\\r\\nConnection: Upgrade\\r\\n'
                       f'Sec-WebSocket-Key: {key}\\r\\nSec-WebSocket-Version: 13\\r\\n\\r\\n')
            sock.sendall(request.encode())
            raw = b''
            while b'\\r\\n\\r\\n' not in raw:
                chunk = sock.recv(4096)
                if not chunk:
                    raise RuntimeError('closed before WebSocket admission')
                raw += chunk
            header, raw = raw.split(b'\\r\\n\\r\\n', 1)
            if b' 101 ' not in header.split(b'\\r\\n', 1)[0]:
                raise RuntimeError('WebSocket admission rejected')

            def take(count):
                global raw
                while len(raw) < count:
                    chunk = sock.recv(max(4096, count - len(raw)))
                    if not chunk:
                        raise RuntimeError('closed before RFB payload')
                    raw += chunk
                value, raw = raw[:count], raw[count:]
                return value

            def receive_frame():
                first, second = take(2)
                length = second & 0x7f
                if length == 126:
                    length = struct.unpack('>H', take(2))[0]
                elif length == 127:
                    length = struct.unpack('>Q', take(8))[0]
                mask = take(4) if second & 0x80 else None
                payload = take(length)
                if mask:
                    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                if first & 0x0f == 8:
                    raise RuntimeError('WebSocket closed before RFB')
                return first & 0x0f, payload

            pending = b''
            def receive_bytes(count):
                global pending
                while len(pending) < count:
                    opcode, payload = receive_frame()
                    if opcode in (0, 2):
                        pending += payload
                value, pending = pending[:count], pending[count:]
                return value

            def send_bytes(payload):
                mask = os.urandom(4)
                length = len(payload)
                if length < 126:
                    header = bytes((0x82, 0x80 | length))
                elif length <= 0xffff:
                    header = bytes((0x82, 0xfe)) + struct.pack('>H', length)
                else:
                    header = bytes((0x82, 0xff)) + struct.pack('>Q', length)
                masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                sock.sendall(header + mask + masked)

            version = receive_bytes(12)
            if not version.startswith(b'RFB '):
                raise RuntimeError('missing RFB server version')
            send_bytes(version)
            count = receive_bytes(1)[0]
            security_types = receive_bytes(count)
            if 1 not in security_types:
                raise RuntimeError('RFB None security unavailable behind viewer token')
            send_bytes(b'\\x01')
            if struct.unpack('>I', receive_bytes(4))[0] != 0:
                raise RuntimeError('RFB security failed')
            send_bytes(b'\\x01')
            server_init = receive_bytes(24)
            width, height = struct.unpack('>HH', server_init[:4])
            name_length = struct.unpack('>I', server_init[20:24])[0]
            receive_bytes(name_length)
            send_bytes(struct.pack('>BBHi', 2, 0, 1, 0))
            send_bytes(struct.pack('>BBHH', 5, 0, width // 2, height // 2))
            send_bytes(struct.pack('>BBHHHH', 3, 0, 0, 0, width, height))
            if receive_bytes(1) != b'\\x00':
                raise RuntimeError('missing framebuffer update')
            print(f'RFB_OK {width}x{height}')
            """

        func crossBotRFB(token: String) throws {
            _ = try BotComputerDockerCLI.defaultRun([
                "exec", containerA, "python3", "-c", rfbScript, serverIP, "6080", token,
            ])
        }

        var viewerReady = false
        for _ in 0..<20 {
            let result = try BotComputerDockerCLI.runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", "-c", rfbScript, "127.0.0.1", hostPort, tokenB],
                timeout: 5
            )
            if result.terminationStatus == 0,
               String(decoding: result.data, as: UTF8.self).contains("RFB_OK") {
                viewerReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(
            viewerReady,
            "B's token through its host-published loopback port must reach an RFB framebuffer"
        )
        XCTAssertThrowsError(try crossBotRFB(token: ""), "a missing token must not reach B's RFB")
        XCTAssertThrowsError(
            try crossBotRFB(token: tokenA),
            "Bot A's own token must not reach Bot B's RFB"
        )
        XCTAssertThrowsError(
            try crossBotRFB(token: String(repeating: "c", count: 32)),
            "a random token must not reach Bot B's RFB"
        )
        for container in [containerA, containerB] {
            XCTAssertNoThrow(
                try BotComputerDockerCLI.defaultRun([
                    "exec", container, "python3", "-c",
                    "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3).read(1)",
                ]),
                "viewer authentication must not disable either Bot's outbound internet access"
            )
        }
        let listeners = try BotComputerDockerCLI.defaultRun([
            "exec", containerB, "python3", "-c",
            """
            for path in ('/proc/net/tcp', '/proc/net/tcp6'):
                for line in open(path).read().splitlines()[1:]:
                    fields = line.split()
                    if fields[3] != '0A':
                        continue
                    raw_ip, raw_port = fields[1].split(':')
                    if set(raw_ip) == {'0'}:
                        scope = 'wildcard'
                    elif raw_ip == '0100007F' or raw_ip == ('0' * 24 + '01000000'):
                        scope = 'loopback'
                    else:
                        scope = 'other'
                    print(f'{scope}:{int(raw_port, 16)}')
            """,
        ])
        let listenerLines = String(decoding: listeners, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(listenerLines.contains("loopback:5900"), "x11vnc must stay loopback-only")
        let nonLoopbackListeners = listenerLines.filter { !$0.hasPrefix("loopback:") }
        XCTAssertEqual(
            nonLoopbackListeners,
            ["wildcard:6080"],
            "the shipped guest must expose no other TCP listener to peer containers"
        )
    }

    func test_BotComputerDocker_timeoutClassificationSeparatesProbeFromProvisioning() {
        // WHY: a slow image build/start is not a daemon health-check timeout;
        // recovery copy must tell the user to retry provisioning, not probing.
        XCTAssertEqual(BotComputerDockerCLI.timeoutError(for: ["info"]), .probeTimedOut)
        XCTAssertEqual(BotComputerDockerCLI.timeoutError(for: ["build"]), .provisioningFailed)
        XCTAssertEqual(BotComputerDockerCLI.timeoutError(for: ["start"]), .provisioningFailed)
    }

    func test_agentExecGetsTheGuestDeadlineWhileShortDockerCommandsStayShort() {
        // WHY: bot_computer_exec runs apt-get/builds that take minutes. A 15 s host
        // timeout failed them as "could not start the desktop". The host deadline
        // must cover the guest deadline yet stay under the MCP child's wait, so the
        // host reports the timeout instead of the child timing out blind.
        let wrapped = BotComputerGuestSpec.deadlineExecCommand("apt-get install -y sl")
        let agentExec = ["exec", "-u", "0", "remotecode-bot-x"] + wrapped
        let workspaceExec = ["exec", "-u", "501:20", "-w", "/Users/ada/repo",
                             "-e", "GIT_AUTHOR_NAME=Ada", "remotecode-bot-x"] + wrapped
        let hostDeadline = BotComputerGuestSpec.execHostDeadlineSeconds
        XCTAssertEqual(BotComputerDockerCLI.timeoutForArguments(agentExec), hostDeadline)
        XCTAssertEqual(BotComputerDockerCLI.timeoutForArguments(workspaceExec), hostDeadline)
        XCTAssertGreaterThan(
            hostDeadline,
            TimeInterval(BotComputerGuestSpec.execGuestDeadlineSeconds + BotComputerGuestSpec.execGuestKillGraceSeconds),
            "the guest `timeout` must fire (and kill) before the host abandons docker exec"
        )
        XCTAssertLessThan(hostDeadline, BotComputerGuestSpec.execResultWaitSeconds)

        // Screenshot/act execs and other docker commands keep failing fast.
        let observe = ["exec", "remotecode-bot-x", "env", "DISPLAY=:1", "import", "-window", "root", "png:-"]
        XCTAssertEqual(BotComputerDockerCLI.timeoutForArguments(observe), 15)
        XCTAssertEqual(BotComputerDockerCLI.timeoutForArguments(["ps", "-aq", "--filter", "name=x"]), 15)
        XCTAssertEqual(BotComputerDockerCLI.timeoutForArguments(["info"]), 5)
        XCTAssertEqual(
            BotComputerDockerCLI.timeoutForArguments(["build", "."]),
            BotComputerGuestSpec.imageBuildDeadlineSeconds
        )
        // A bare `bash -lc` exec (unbounded in the guest) gets no long host deadline.
        XCTAssertEqual(
            BotComputerDockerCLI.timeoutForArguments(["exec", "remotecode-bot-x", "bash", "-lc", "sleep 60"]),
            15
        )
    }

    func test_shortenedGuestBudgetShortensTheHostDeadlineToMatch() {
        // WHY: an exec that waited for provisioning gets a smaller guest limit;
        // the host docker deadline must follow that limit, not the full one, or
        // the host would still be waiting after the MCP caller gave up.
        let agentExec = ["exec", "remotecode-bot-x"]
            + BotComputerGuestSpec.deadlineExecCommand("make", guestSeconds: 40)
        XCTAssertEqual(
            BotComputerDockerCLI.timeoutForArguments(agentExec),
            BotComputerGuestSpec.execHostDeadline(guestSeconds: 40)
        )
        XCTAssertEqual(BotComputerDockerCLI.timeoutError(for: agentExec), .guestCommandTimedOut(seconds: 40))
    }

    func test_agentExecTimeoutIsReportedAsACommandTimeoutNotADesktopFailure() {
        // WHY: "Could not start the Linux desktop" sends the agent chasing Docker
        // when its own command simply ran too long.
        let full = BotComputerGuestSpec.execGuestDeadlineSeconds
        let agentExec = ["exec", "remotecode-bot-x"] + BotComputerGuestSpec.deadlineExecCommand("make")
        let ranTheFullLimit = TimeInterval(full) + 0.4
        XCTAssertEqual(BotComputerDockerCLI.timeoutError(for: agentExec), .guestCommandTimedOut(seconds: full))
        XCTAssertTrue(
            BotComputerDockerCLI.isGuestDeadlineExit(agentExec, status: 124, elapsed: ranTheFullLimit),
            "timeout sent TERM"
        )
        XCTAssertTrue(
            BotComputerDockerCLI.isGuestDeadlineExit(agentExec, status: 137, elapsed: ranTheFullLimit),
            "timeout had to KILL"
        )
        XCTAssertFalse(BotComputerDockerCLI.isGuestDeadlineExit(agentExec, status: 1, elapsed: ranTheFullLimit))
        XCTAssertFalse(
            BotComputerDockerCLI.isGuestDeadlineExit(["exec", "x", "false"], status: 124, elapsed: ranTheFullLimit)
        )
        let message = BotComputerDockerError.guestCommandTimedOut(seconds: full).description
        XCTAssertTrue(message.contains("\(full) s"))
        XCTAssertNotEqual(message, BotComputerDockerError.provisioningFailed.description)
    }

    func test_ownTimeoutOrOOMExitBeforeTheGuestLimitIsNotReportedAsTheGuestDeadline() {
        // WHY: agents run `timeout 10 curl ...` (exit 124 after 10 s) and an
        // OOM-killed command exits 137 within seconds. Telling the agent "ran
        // longer than 165 s and was stopped" for those is false.
        let agentExec = ["exec", "remotecode-bot-x"] + BotComputerGuestSpec.deadlineExecCommand("timeout 10 curl x")
        XCTAssertFalse(BotComputerDockerCLI.isGuestDeadlineExit(agentExec, status: 124, elapsed: 10.2))
        XCTAssertFalse(BotComputerDockerCLI.isGuestDeadlineExit(agentExec, status: 137, elapsed: 3))
    }
    /// A busy daemon that misses the first short `docker info` must not fail
    /// the run: the screenshot case stalled a Bot conversation until Retry.
    func testTimedOutProbeRetriesWithLongerTimeoutThenSucceeds() throws {
        final class Calls: @unchecked Sendable { var timeouts: [TimeInterval] = [] }
        let calls = Calls()
        let resolver = BotComputerDockerResolver(candidates: ["/bin/echo"], probeTimeout: 0.1) { _, timeout in
            calls.timeouts.append(timeout)
            return calls.timeouts.count == 1 ? .timedOut : .healthy
        }
        XCTAssertEqual(try resolver.resolveHealthyExecutable(), "/bin/echo")
        XCTAssertEqual(calls.timeouts.count, 2)
        XCTAssertGreaterThan(calls.timeouts[1], calls.timeouts[0])
    }

    /// Retrying a stopped daemon only delays the real message.
    func testStoppedDaemonFailsWithoutRetry() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let resolver = BotComputerDockerResolver(candidates: ["/bin/echo"], probeTimeout: 0.1) { _, _ in
            calls.count += 1
            return .failed
        }
        XCTAssertThrowsError(try resolver.resolveHealthyExecutable()) {
            XCTAssertEqual($0 as? BotComputerDockerError, .daemonUnavailable)
        }
        XCTAssertEqual(calls.count, 1)
    }

    /// The send preflight calls `info()` after the resolver is cached; one slow answer must not fail the send.
    func testInfoRetriesTimeoutButNotStoppedDaemon() throws {
        final class Count: @unchecked Sendable { var n = 0 }
        let slow = Count()
        let client = BotComputerDockerCLI { _ in
            slow.n += 1
            if slow.n == 1 { throw BotComputerDockerError.probeTimedOut }
            return Data("ok".utf8)
        }
        XCTAssertEqual(try client.info(), "ok")
        let stopped = Count()
        let down = BotComputerDockerCLI { _ in stopped.n += 1; throw BotComputerDockerError.daemonUnavailable }
        XCTAssertThrowsError(try down.info())
        XCTAssertEqual(stopped.n, 1)
    }

    func testProbeThatKeepsTimingOutStillReportsTimeout() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let resolver = BotComputerDockerResolver(candidates: ["/bin/echo"], probeTimeout: 0.1) { _, _ in
            calls.count += 1
            return .timedOut
        }
        XCTAssertThrowsError(try resolver.resolveHealthyExecutable()) {
            XCTAssertEqual($0 as? BotComputerDockerError, .probeTimedOut)
        }
        XCTAssertEqual(calls.count, 3)
    }
}

private final class DockerNetworkRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let networkName: String
    private var explicitAttemptCount = 0
    private var recordedCalls: [[String]] = []

    init(networkName: String) {
        self.networkName = networkName
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(_ args: [String]) throws -> Data {
        lock.lock()
        recordedCalls.append(args)
        if args.starts(with: ["network", "create"]), args.contains("--subnet") {
            explicitAttemptCount += 1
            let attempt = explicitAttemptCount
            lock.unlock()
            if attempt == 1 {
                throw BotComputerDockerError.networkSubnetUnavailable
            }
            return Data()
        }
        lock.unlock()
        if args == ["network", "create", networkName] {
            throw BotComputerDockerError.networkAddressPoolExhausted
        }
        if args == ["network", "inspect", networkName] {
            throw BotComputerDockerError.provisioningFailed
        }
        throw BotComputerDockerError.provisioningFailed
    }

}
