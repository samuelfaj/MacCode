import XCTest
import CoreModel

final class BotComputerGuestSpecTests: XCTestCase {
    func test_createOptionsForceLoopbackAndRejectForeignHome() throws {
        // WHY: HostIp 0.0.0.0 would publish noVNC on the LAN. A bind of
        // $HOME or BotHome would leak this Mac into the guest.
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-app-support-spec")
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path
        let viewerToken = String(repeating: "a", count: 32)
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home,
            appSupport: support,
            viewerToken: viewerToken
        )
        XCTAssertEqual(options.hostIP, "127.0.0.1")
        XCTAssertEqual(options.hostPort, 0)
        XCTAssertEqual(options.image, BotComputerGuestSpec.imageTag)
        XCTAssertEqual(options.capDrop, [])
        XCTAssertEqual(options.capAdd, [])
        XCTAssertEqual(options.securityOptions, [])
        XCTAssertEqual(options.tmpfs, [])
        XCTAssertNil(options.labels["remotecode.context.network"])
        XCTAssertNil(options.environment["REMOTECODE_CONTEXT_NETWORK_POLICY"])
        XCTAssertEqual(options.labels["remotecode.managed"], "1")
        XCTAssertTrue(options.binds.first?.hasPrefix(home) == true)
        XCTAssertEqual(options.network, BotComputerGuestSpec.networkName(botID: botID))
        XCTAssertEqual(
            options.environment["REMOTECODE_VIEWER_TOKEN"],
            viewerToken
        )
        XCTAssertGreaterThanOrEqual(options.shmSize, BotComputerGuestSpec.minimumShmBytes)
        let recipe = BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID).path
        XCTAssertEqual(recipe, home,
            "each bot's editable Dockerfile must live directly in that bot's persisted guest home")
        XCTAssertNotEqual(
            recipe,
            BotComputerGuestSpec.recipeURL(appSupport: support, botID: BotID()).path,
            "Docker build contexts must remain isolated per bot"
        )
        XCTAssertTrue(BotComputerGuestSpec.execUsesRoot("apt-get install -y sl"))
        XCTAssertFalse(BotComputerGuestSpec.execUsesRoot("ls"))

        XCTAssertThrowsError(
            try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: "/tmp/evil",
                appSupport: support,
                viewerToken: viewerToken
            )
        )
        XCTAssertThrowsError(
            try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: NSHomeDirectory(),
                appSupport: support,
                viewerToken: viewerToken
            )
        )
        let url = try BotComputerGuestSpec.screenURL(hostPort: 49152, token: viewerToken)
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/vnc.html")
        XCTAssertTrue(url.query?.contains("autoconnect=1") == true)
        XCTAssertTrue(url.query?.contains("view_only=0") == true)
        // WHY: noVNC plays bell.oga whenever the guest xterm rings; the
        // viewer must stay silent (ui.js only plays when bell == "on").
        XCTAssertTrue(url.query?.contains("bell=off") == true)
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "path" })?.value,
            "websockify?token=\(viewerToken)"
        )
        XCTAssertThrowsError(try BotComputerGuestSpec.screenURL(hostPort: 49152, token: "guessable"))
        XCTAssertThrowsError(try BotComputerGuestSpec.validateScreenURL(URL(string: "http://0.0.0.0:6080/")!))
        XCTAssertThrowsError(try BotComputerGuestSpec.viewerURL(URL(string: "http://0.0.0.0:6080/")!))
        let loopback = try BotComputerGuestSpec.viewerURL(url)
        XCTAssertEqual(loopback.host, "127.0.0.1")
    }

    func test_ensureNetworkCreatesABridgeNotAnInternalNetwork() throws {
        // WHY: --internal would block apt-get and Chromium on the guest.
        var seen: [[String]] = []
        let cli = BotComputerDockerCLI(run: { args in
            seen.append(args)
            return Data()
        })
        try cli.ensureNetwork(name: "remotecode-bot-example")
        XCTAssertEqual(seen.first, ["network", "create", "remotecode-bot-example"])
        XCTAssertFalse(seen.contains(where: { $0.contains("--internal") }))
    }

    func test_inspectFormatSurvivesAStoppedContainer() throws {
        // WHY: Docker clears published ports on stop. The old Go template
        // crashed inspect, so Start after Stop treated the guest as missing
        // and docker create failed on the leftover name.
        var formats: [String] = []
        let cli = BotComputerDockerCLI(run: { args in
            if args.first == "inspect" {
                if let idx = args.firstIndex(of: "-f"), args.index(after: idx) < args.endIndex {
                    formats.append(args[args.index(after: idx)])
                }
                return Data("false sha256:img 0\n".utf8)
            }
            return Data()
        })
        let inspect = try cli.inspect(name: "remotecode-bot-example")
        XCTAssertFalse(inspect.running)
        XCTAssertEqual(inspect.hostPort, 0)
        XCTAssertFalse(
            formats.contains(where: { $0.contains("index (index .NetworkSettings.Ports") }),
            "inspect must not index Ports[0] on a stopped container"
        )
        XCTAssertTrue(formats.contains(where: { $0.contains("{{else}}0{{end}}") }))
    }

    func test_notReadyErrorCopyIsHuman_becauseSaveBotMustNotAlertCaseName() {
        // WHY: Save Bot presented String(describing:) of the enum case, so
        // the owner saw an alert titled Bots with the body "notReady".
        XCTAssertEqual(BotComputerGuestError.notReady.description, "Docker desktop is not ready.")
        XCTAssertEqual(BotComputerGuestError.notReady.errorDescription, "Docker desktop is not ready.")
        XCTAssertEqual(String(describing: BotComputerGuestError.notReady), "Docker desktop is not ready.")
        XCTAssertNotEqual(String(describing: BotComputerGuestError.notReady), "notReady")
    }

    func test_playwrightMCPCommandDrivesGuestChromiumHeadedOnXvfb() {
        // WHY: the host bridge builds `docker exec -i <container>` around this
        // exact argv; a drifted flag silently breaks bot browsing. It must run
        // headed on DISPLAY=:1 so the user can watch/log in via the guest
        // screen, and use /usr/bin/chromium so Playwright never downloads
        // browsers in the guest.
        XCTAssertEqual(BotComputerGuestSpec.playwrightMCPCommand(), [
            "env", "DISPLAY=:1",
            "npx", "--yes", "@playwright/mcp@latest",
            "--executable-path", "/usr/bin/chromium",
            "--no-sandbox",
            "--user-data-dir", "/home/remotecode/.browser-profiles/playwright",
        ])
        XCTAssertEqual(
            Array(BotComputerGuestSpec.playwrightMCPCommand(userDataDir: "/home/remotecode/custom").suffix(2)),
            ["--user-data-dir", "/home/remotecode/custom"]
        )
        XCTAssertTrue(
            BotComputerGuestSpec.playwrightGuestUserDataDir.hasPrefix(BotComputerGuestSpec.guestUserHome + "/"),
            "the profile must live in the bind-mounted guest home so logins persist"
        )
    }

    func test_recipeRevision8ShipsTheInGuestAgentToolchain() throws {
        // WHY: the bot's agent runs inside this image. It needs git and ps for
        // its own shell, wmctrl + xwd for linux-use, and a pinned Playwright MCP
        // that only runs on Node >= 20 (bookworm's apt node is 18). Only the
        // revision bump makes existing guests pick the recipe up, and the tag
        // carries the revision so another app build on r4 never rebuilds it.
        XCTAssertEqual(BotComputerGuestSpec.recipeRevision, "8")
        XCTAssertEqual(BotComputerGuestSpec.imageTag, "remotecode/computer:r8")
        XCTAssertEqual(BotComputerGuestSpec.runtimeRevision, "8")
        XCTAssertTrue(BotComputerGuestSpec.recipeFileNames.contains("context-network.sh"))
        let recipe = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/Resources/ComputerGuest")
        let dockerfile = try String(contentsOf: recipe.appendingPathComponent("Dockerfile"), encoding: .utf8)
        for package in ["git", "procps", "wmctrl", "x11-apps", "xdotool", "imagemagick", "python3", "fluxbox"] {
            XCTAssertTrue(dockerfile.contains("        \(package) \\\n"), "missing apt package \(package)")
        }
        XCTAssertFalse(dockerfile.contains("        nodejs \\\n"), "apt nodejs is 18; Playwright refuses to start on it")
        XCTAssertTrue(dockerfile.contains("node-v24.21.0-linux-${node_arch}.tar.xz"))
        XCTAssertTrue(dockerfile.contains("sha256sum -c -"), "the Node download must be checksum-verified")
        XCTAssertTrue(dockerfile.contains("npm install -g @playwright/mcp@0.0.83"))
        XCTAssertTrue(dockerfile.contains("PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1"))
        XCTAssertFalse(dockerfile.contains("@playwright/mcp@latest"))

        let browser = try String(contentsOf: recipe.appendingPathComponent("launch-browser.sh"), encoding: .utf8)
        XCTAssertTrue(browser.contains("--remote-debugging-port=9222"),
            "Playwright MCP attaches to the visible browser so viewer logins are the bot's session")
        XCTAssertTrue(browser.contains("--remote-debugging-address=127.0.0.1"),
            "CDP must stay on the guest loopback")
    }

    func test_contextNetworkScriptKeepsOneGatewayLeasePerRun() throws {
        // WHY: several conversations share one bot VM. A single gateway slot
        // made the second run's lease fail, and revoking one run must not cut
        // another run's endpoint.
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/Resources/ComputerGuest/context-network.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("state_dir=/run/remotecode-context-gateways"))
        XCTAssertTrue(script.contains("write_lease \"$run\" \"$ip\" \"$port\" active"))
        XCTAssertTrue(script.contains("[ \"$lease_ip:$lease_port\" != \"$ip:$port\" ] || [ \"$lease_state\" = revoked ] || exit 1"),
            "two live runs must never share one endpoint")
        XCTAssertFalse(script.contains("state=/run/remotecode-context-gateway\n"), "the single-lease slot is gone")
    }

    func test_contextualNetworkPolicyAddsPrivateEgressMarkersAndLeastPrivilegeOptions() throws {
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-context-network")
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path,
            appSupport: support,
            viewerToken: String(repeating: "a", count: 32),
            contextualNetworkPolicy: true
        )
        XCTAssertEqual(options.labels["remotecode.context.network"], "private-egress-v1")
        XCTAssertEqual(options.environment["REMOTECODE_CONTEXT_NETWORK_POLICY"], "private-egress-v1")
        XCTAssertEqual(options.capDrop, ["ALL"])
        XCTAssertEqual(options.capAdd, ["NET_ADMIN"])
        XCTAssertEqual(options.securityOptions, ["no-new-privileges:true"])
        XCTAssertEqual(options.tmpfs, ["/run:rw,nosuid,nodev,noexec,mode=0755"])
        XCTAssertEqual(options.image, "remotecode/computer:r8")
    }

    func test_createOptionsMountTheAgentKitReadOnlyAndRunAnInitWithTheHostAlias() throws {
        // WHY: the in-guest agent runs from /opt/remotecode-agent, which the guest
        // must not be able to rewrite; --init reaps the agent's orphans; the
        // agent reaches host loopback services as host.docker.internal on every
        // Docker runtime. The runtime label lets older containers be replaced.
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-app-support-spec")
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path,
            appSupport: support,
            viewerToken: String(repeating: "a", count: 32)
        )
        XCTAssertEqual(
            options.binds.last,
            "/tmp/rc-app-support-spec/guest-tools:/opt/remotecode-agent:ro"
        )
        XCTAssertTrue(options.initProcess)
        XCTAssertEqual(options.extraHosts, ["host.docker.internal:host-gateway"])
        XCTAssertEqual(options.labels[BotComputerGuestSpec.runtimeLabelKey], BotComputerGuestSpec.runtimeRevision)
    }

    func test_enforcedDockerIgnoreKeepsSecretsOutEvenAfterAGuestEdit() {
        // WHY: the build context is the guest-writable home, which holds the
        // agent's credentials (.distill), run leases (.rc-*) and browser cookies.
        // Docker applies the last matching line, so the exclusions must always
        // come last: a guest-written "!.distill/..." above them cannot win.
        let hostile = "node_modules\n!.distill/claude-auth.json\n.distill\n# RemoteCode: always excluded (rewritten before every build)\n.rc-*\n"
        let enforced = BotComputerGuestSpec.enforcedDockerIgnore(hostile)
        let lines = enforced.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.suffix(3)), BotComputerGuestSpec.requiredDockerIgnorePatterns)
        XCTAssertTrue(lines.contains("node_modules"), "the user's own exclusions stay")
        XCTAssertEqual(lines.filter { $0 == ".distill" }.count, 1)
        XCTAssertEqual(BotComputerGuestSpec.enforcedDockerIgnore(enforced), enforced,
            "already-enforced content is left unchanged, so it is not rewritten on every provision")
        XCTAssertEqual(
            BotComputerGuestSpec.enforcedDockerIgnore(nil),
            "# RemoteCode: always excluded (rewritten before every build)\n.distill\n.rc-*\n.browser-profiles\n"
        )
    }

    func test_execGuestBudgetFitsTheCallersRemainingWait() {
        // WHY: the MCP caller's wait starts when it queues the exec; queueing and
        // provisioning eat into it. The guest limit must leave room for the kill
        // grace, docker teardown and the result write, so the host still answers
        // before the caller gives up.
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = now.addingTimeInterval(BotComputerGuestSpec.execResultWaitSeconds)
        XCTAssertEqual(
            BotComputerGuestSpec.execGuestBudgetSeconds(deadline: fresh, now: now),
            BotComputerGuestSpec.execGuestDeadlineSeconds,
            "a warm exec keeps the full advertised limit"
        )
        XCTAssertEqual(
            BotComputerGuestSpec.execGuestBudgetSeconds(deadline: nil, now: now),
            BotComputerGuestSpec.execGuestDeadlineSeconds
        )

        for remaining in [17.0, 40.0, 100.5, 179.9] {
            let deadline = now.addingTimeInterval(remaining)
            guard let seconds = BotComputerGuestSpec.execGuestBudgetSeconds(deadline: deadline, now: now) else {
                XCTFail("remaining \(remaining) s should still run the command")
                continue
            }
            XCTAssertGreaterThanOrEqual(seconds, BotComputerGuestSpec.execMinimumGuestSeconds)
            let answeredBy = BotComputerGuestSpec.execHostDeadline(guestSeconds: seconds)
                + TimeInterval(BotComputerGuestSpec.execResultMarginSeconds)
            XCTAssertLessThanOrEqual(answeredBy, remaining, "remaining \(remaining) s")
        }

        XCTAssertNil(
            BotComputerGuestSpec.execGuestBudgetSeconds(deadline: now.addingTimeInterval(16.9), now: now),
            "too little left to run anything: refuse instead of starting a doomed command"
        )
        XCTAssertNil(BotComputerGuestSpec.execGuestBudgetSeconds(deadline: now.addingTimeInterval(-1), now: now))
    }

    func test_execGuestSecondsReadsOnlyWrappedAgentCommands() {
        let wrapped = ["exec", "-u", "0", "c"] + BotComputerGuestSpec.deadlineExecCommand("ls", guestSeconds: 42)
        XCTAssertEqual(BotComputerGuestSpec.execGuestSeconds(inExecArguments: wrapped), 42)
        XCTAssertNil(BotComputerGuestSpec.execGuestSeconds(inExecArguments: ["exec", "c", "bash", "-lc", "ls"]))
        XCTAssertNil(
            BotComputerGuestSpec.execGuestSeconds(inExecArguments: ["exec", "c", "timeout", "-k", "5", "9", "curl", "x"]),
            "the agent's own timeout is not the guest deadline wrapper"
        )
    }
}
