import XCTest
@testable import CoreModel

/// No real npx/docker/network anywhere in this file: the host is exercised
/// through a fake child factory and fake executable resolvers.
final class BotBrowserPlaywrightBridgeTests: XCTestCase {
    // MARK: Translator

    func test_kindLiteralsMirrorBotBrowserCatalog_becauseCoreModelCannotImportPersistence() {
        // WHY: the translator matches literal kind strings because
        // BotBrowserCatalog lives a layer above. Drift here would silently
        // route every host action into the unknown-kind error.
        XCTAssertEqual(BotBrowserPlaywrightKind.open, "bot_browser_open")
        XCTAssertEqual(BotBrowserPlaywrightKind.snapshot, "bot_browser_snapshot")
        XCTAssertEqual(BotBrowserPlaywrightKind.act, "bot_browser_act")
        XCTAssertEqual(BotBrowserPlaywrightKind.state, "state")
    }

    func test_translatorMapsEveryKindToTheVerifiedPlaywrightTool() throws {
        // WHY: these names/props were verified live against
        // `npx @playwright/mcp@latest` on 2026-08-21; a wrong tool name or a
        // missing required property makes every bot action fail upstream.
        let open = try BotBrowserPlaywrightTranslator.request(
            kind: "bot_browser_open", action: "", ref: "", text: "", url: "https://a.test",
            refParameterName: "target"
        )
        XCTAssertEqual(open.name, "browser_navigate")
        XCTAssertEqual(open.arguments["url"] as? String, "https://a.test")

        for kind in ["bot_browser_snapshot", "state"] {
            let snapshot = try BotBrowserPlaywrightTranslator.request(
                kind: kind, action: "", ref: "", text: "", url: "", refParameterName: "target"
            )
            XCTAssertEqual(snapshot.name, "browser_snapshot")
            XCTAssertTrue(snapshot.arguments.isEmpty, "browser_snapshot requires no properties")
        }

        let click = try BotBrowserPlaywrightTranslator.request(
            kind: "bot_browser_act", action: "click", ref: "e3", text: "", url: "",
            refParameterName: "target"
        )
        XCTAssertEqual(click.name, "browser_click")
        XCTAssertEqual(click.arguments["target"] as? String, "e3", "bare ref token, not [ref=e3]")
        XCTAssertEqual(click.arguments["element"] as? String, "ref e3")

        for action in ["type", "fill"] {
            let typed = try BotBrowserPlaywrightTranslator.request(
                kind: "bot_browser_act", action: action, ref: "e7", text: "hello", url: "",
                refParameterName: "target"
            )
            XCTAssertEqual(typed.name, "browser_type", "\(action) rides browser_type")
            XCTAssertEqual(typed.arguments["target"] as? String, "e7")
            XCTAssertEqual(typed.arguments["text"] as? String, "hello")
        }

        let scroll = try BotBrowserPlaywrightTranslator.request(
            kind: "bot_browser_act", action: "scroll", ref: "e1", text: "", url: "",
            refParameterName: "target"
        )
        XCTAssertEqual(scroll.name, "browser_press_key")
        XCTAssertEqual(scroll.arguments["key"] as? String, "PageDown")
    }

    func test_translatorUsesIntrospectedRefParameterName_becauseServersRenamedIt() throws {
        // WHY: current servers take `target`, older ones took `ref`; sending
        // the wrong one is a schema error on every click/type.
        let old = try BotBrowserPlaywrightTranslator.request(
            kind: "bot_browser_act", action: "click", ref: "e3", text: "", url: "",
            refParameterName: "ref"
        )
        XCTAssertEqual(old.arguments["ref"] as? String, "e3")
        XCTAssertNil(old.arguments["target"])
    }

    func test_translatorFailsLoudOnUnknownKindOrAction() {
        // WHY: silently mapping garbage would drive the wrong tool on a live
        // logged-in browser.
        XCTAssertThrowsError(try BotBrowserPlaywrightTranslator.request(
            kind: "bot_browser_get", action: "", ref: "", text: "", url: "", refParameterName: "target"
        ))
        XCTAssertThrowsError(try BotBrowserPlaywrightTranslator.request(
            kind: "bot_browser_act", action: "hover", ref: "e1", text: "", url: "", refParameterName: "target"
        ))
    }

    func test_parseJoinsTextPartsAndReportsUpstreamErrorsVerbatim() {
        // WHY: fail-loud contract — the bot must read the upstream failure
        // text, never a swallowed/rewritten one.
        let ok = BotBrowserPlaywrightTranslator.parse(result: [
            "result": [
                "content": [
                    ["type": "text", "text": "### Page"],
                    ["type": "image", "data": "ignored"],
                    ["type": "text", "text": "- Page URL: https://a.test"],
                ],
                "isError": false,
            ],
        ])
        XCTAssertEqual(ok.text, "### Page\n- Page URL: https://a.test")
        XCTAssertFalse(ok.isError)

        let toolError = BotBrowserPlaywrightTranslator.parse(result: [
            "result": [
                "content": [["type": "text", "text": "Ref e9 not found in the current page snapshot"]],
                "isError": true,
            ],
        ])
        XCTAssertTrue(toolError.isError)
        XCTAssertEqual(toolError.text, "Ref e9 not found in the current page snapshot")

        let protocolError = BotBrowserPlaywrightTranslator.parse(result: [
            "error": ["code": -32602, "message": "Invalid params"],
        ])
        XCTAssertTrue(protocolError.isError)
        XCTAssertEqual(protocolError.text, "Invalid params")
    }

    func test_pageStateScanToleratesPrefixVariantsAndMissingLines() {
        // WHY: waitLogin rides the URL parsed from this text; a prefix change
        // upstream must not blind login detection.
        let dashed = BotBrowserPlaywrightTranslator.pageState(fromSnapshotText: """
        ### Page
        - Page URL: https://a.test/home
        - Page Title: Home
        ### Snapshot
        - button "Go" [ref=e4]
        """)
        XCTAssertEqual(dashed.url, "https://a.test/home")
        XCTAssertEqual(dashed.title, "Home")

        let bare = BotBrowserPlaywrightTranslator.pageState(fromSnapshotText: """
        Page URL: https://b.test/in
        Page Title: Sign in
        """)
        XCTAssertEqual(bare.url, "https://b.test/in")
        XCTAssertEqual(bare.title, "Sign in")

        let missing = BotBrowserPlaywrightTranslator.pageState(fromSnapshotText: "clicked ok")
        XCTAssertNil(missing.url)
        XCTAssertNil(missing.title)

        let emptyValue = BotBrowserPlaywrightTranslator.pageState(fromSnapshotText: "- Page URL: \n- Page Title: ")
        XCTAssertNil(emptyValue.url, "empty value must not clobber lastKnown with blank")
        XCTAssertNil(emptyValue.title)
    }

    func test_refParameterIntrospectionPrefersTargetElseRef() {
        // WHY: the rename (`ref` → `target`) shipped mid-stream on @latest;
        // the child must pick per server, defaulting to current.
        func toolsList(_ properties: [String: Any]) -> [String: Any] {
            ["result": ["tools": [["name": "browser_click", "inputSchema": ["properties": properties]]]]]
        }
        XCTAssertEqual(
            BotBrowserPlaywrightChild.refParameterName(fromToolsList: toolsList(["target": [:], "element": [:]])),
            "target"
        )
        XCTAssertEqual(
            BotBrowserPlaywrightChild.refParameterName(fromToolsList: toolsList(["ref": [:], "element": [:]])),
            "ref"
        )
        XCTAssertEqual(
            BotBrowserPlaywrightChild.refParameterName(fromToolsList: ["result": ["tools": [[String: Any]]()]]),
            "target",
            "unknown server shape defaults to the current name"
        )
    }

    // MARK: Host argv

    func test_localArgvPinnedExactly_becauseItIsTheBotsOwnChromeContract() {
        // WHY: `--browser chrome` (owner-installed Google Chrome binary) and
        // the per-bot profile dir ARE the user requirement "if the bot has
        // its own browser it must be a playwright" — any drift changes which
        // browser/profile a logged-in bot session lands in.
        let appSupport = URL(fileURLWithPath: "/tmp/rc-app-support", isDirectory: true)
        let botID = BotID(UUID(uuidString: "6BAB5F94-9A5B-4C29-8FAE-4B4A78E93A0C")!)
        let profile = BotBrowserPlaywrightHost.localProfileDirectory(appSupport: appSupport, botID: botID)
        XCTAssertEqual(
            profile.path,
            "/tmp/rc-app-support/BotBrowsers/6bab5f94-9a5b-4c29-8fae-4b4a78e93a0c/playwright",
            "profile sits beside the bot's BotBrowserStore data, keyed lowercased"
        )
        XCTAssertEqual(
            BotBrowserPlaywrightHost.localArguments(npxPath: "/opt/homebrew/bin/npx", profileDirectory: profile.path),
            [
                "/opt/homebrew/bin/npx", "--yes", "--prefer-offline", "@playwright/mcp@latest",
                "--browser", "chrome",
                "--user-data-dir", profile.path,
            ]
        )
    }

    func test_guestArgvPinnedExactly_becauseTheGuestLaneIsDockerExecPlusWave1Command() {
        // WHY: the docker lane must exec into THIS bot's guest container and
        // run exactly the wave-1 in-guest Playwright command (headed chromium
        // on :1 so the user can log in through the guest screen).
        let botID = BotID(UUID(uuidString: "6BAB5F94-9A5B-4C29-8FAE-4B4A78E93A0C")!)
        XCTAssertEqual(
            BotBrowserPlaywrightHost.guestArguments(dockerPath: "/usr/local/bin/docker", botID: botID),
            ["/usr/local/bin/docker", "exec", "-i", "remotecode-bot-6bab5f94-9a5b-4c29-8fae-4b4a78e93a0c"]
                + BotComputerGuestSpec.playwrightMCPCommand()
        )
    }

    func test_npxResolutionScansPATHThenKnownHomes_andFailsWithInstallGuidance() throws {
        // WHY: the GUI app's PATH is minimal; on real machines npx lives in
        // ~/.local/bin or /opt/homebrew/bin. Missing npx must say what to
        // install, not throw a generic spawn error.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-npx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let npx = binDir.appendingPathComponent("npx")
        try Data("#!/bin/sh\n".utf8).write(to: npx)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)

        XCTAssertEqual(
            try BotBrowserPlaywrightHost.resolveNPXExecutable(
                pathEnvironment: binDir.path,
                homeDirectory: root.path
            ),
            npx.path
        )
        // Same binary found via the ~/.local/bin fallback when PATH is empty.
        let home = root.appendingPathComponent("home", isDirectory: true)
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let homeNPX = localBin.appendingPathComponent("npx")
        try FileManager.default.copyItem(at: npx, to: homeNPX)
        XCTAssertEqual(
            try BotBrowserPlaywrightHost.resolveNPXExecutable(pathEnvironment: "", homeDirectory: home.path),
            homeNPX.path
        )

        // Hermetic missing case: this machine has real npx installs in the
        // hardcoded fallback homes, so pin the scan loop + message directly.
        XCTAssertThrowsError(
            try BotBrowserPlaywrightHost.resolveNPXExecutable(
                searchDirectories: [root.appendingPathComponent("missing").path]
            )
        ) { error in
            XCTAssertEqual(String(describing: error), BotBrowserPlaywrightHost.npxMissingMessage)
            XCTAssertTrue(String(describing: error).contains("Node 18+"))
        }
    }

    func test_childEnvironmentWidensPATHForTheNodeShebang() {
        // WHY: npx is `#!/usr/bin/env node`; spawning it by absolute path
        // still fails unless PATH reaches a node install.
        let environment = BotBrowserPlaywrightHost.childEnvironment(base: ["PATH": "/usr/bin"])
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1, "no duplicate entries")
    }

    // MARK: Host + fake child

    private final class FakeChild: BotBrowserPlaywrightChildProcessing, @unchecked Sendable {
        private let lock = NSLock()
        var refName = "target"
        var nextResponse: [String: Any] = FakeChild.pageResponse(url: "https://a.test/home", title: "Home")
        var callError: Error?
        var handshakeError: Error?
        private(set) var calls: [(name: String, arguments: [String: Any])] = []
        private(set) var terminateCount = 0

        static func pageResponse(url: String, title: String) -> [String: Any] {
            [
                "result": [
                    "content": [[
                        "type": "text",
                        "text": "### Page\n- Page URL: \(url)\n- Page Title: \(title)\n### Snapshot",
                    ]],
                    "isError": false,
                ],
            ]
        }

        func resolveRefParameterName() throws -> String {
            if let handshakeError { throw handshakeError }
            return refName
        }

        func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
            lock.lock()
            calls.append((name, arguments))
            let error = callError
            let response = nextResponse
            lock.unlock()
            if let error { throw error }
            return response
        }

        func terminate() {
            lock.lock()
            terminateCount += 1
            lock.unlock()
        }
    }

    private func makeHost(
        children: @escaping @Sendable ([String], [String: String]?) -> any BotBrowserPlaywrightChildProcessing
    ) -> BotBrowserPlaywrightHost {
        BotBrowserPlaywrightHost(
            makeChild: children,
            resolveNPX: { "/fake/npx" },
            resolveDocker: { "/fake/docker" }
        )
    }

    func test_hostRefusedRouteThrowsTheRefusalMessage_andSpawnsNothing() {
        // WHY: an explicitly refused runtime must fail loud; the Playwright
        // host must not even build a child for it.
        let spawnCounter = SpawnCounter()
        let host = makeHost(children: { _, _ in
            spawnCounter.increment()
            return FakeChild()
        })
        XCTAssertThrowsError(
            try host.perform(
                botID: BotID(), route: .refused(BotBrowserRoute.refusedMessage),
                kind: "bot_browser_open", action: "", ref: "", text: "",
                url: "https://a.test", appSupport: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(String(describing: error), BotBrowserRoute.refusedMessage)
            XCTAssertTrue(String(describing: error).contains("unavailable"))
        }
        XCTAssertEqual(spawnCounter.count, 0)
    }

    private final class SpawnCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        private(set) var argvs: [[String]] = []
        func record(_ argv: [String]) {
            lock.lock()
            count += 1
            argvs.append(argv)
            lock.unlock()
        }
        func increment() { record([]) }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    func test_idleChildrenAreTerminated_becauseDeletedBotsMustNotKeepBrowsersAliveForMonths() throws {
        // WHY: the registry kept one Node/Chrome child per bot that ever browsed,
        // including deleted bots, for the whole app lifetime.
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-pw-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let clock = TestClock()
        let spawned = SpawnedChildren()
        let host = BotBrowserPlaywrightHost(
            makeChild: { _, _ in spawned.make() },
            resolveNPX: { "/fake/npx" },
            resolveDocker: { "/fake/docker" },
            idleChildTimeout: 60,
            now: { clock.now }
        )
        func open(_ bot: BotID) throws {
            _ = try host.perform(botID: bot, route: .playwrightLocal, kind: "bot_browser_open", action: "", ref: "",
                                 text: "", url: "https://a.test/home", appSupport: appSupport)
        }
        let deleted = BotID(), active = BotID()
        try open(deleted)
        try open(active)
        clock.advance(45)
        try open(active)
        clock.advance(30)

        // `deleted` has been idle 75 s; `active` only 30 s.
        host.evictIdleChildren()
        XCTAssertEqual(spawned.children[0].terminateCount, 1, "idle child must be terminated")
        XCTAssertEqual(spawned.children[1].terminateCount, 0, "recently used child stays")

        clock.advance(120)
        try open(deleted)
        XCTAssertEqual(spawned.children[1].terminateCount, 1, "every perform sweeps other idle children")
        XCTAssertEqual(spawned.children.count, 3, "a returning bot gets a fresh child")
        XCTAssertEqual(spawned.children.last?.terminateCount, 0)
    }

    private final class SpawnedChildren: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeChild] = []
        var children: [FakeChild] { lock.lock(); defer { lock.unlock() }; return made }
        func make() -> FakeChild {
            let child = FakeChild()
            lock.lock(); made.append(child); lock.unlock()
            return child
        }
    }

    func test_hostReusesOneChildPerBot_andReturnsURLTitleContent() throws {
        // WHY: respawning per call would lose the logged-in Chrome; the
        // payload shape {url,title,content} is what the router persists and
        // the MCP returns to the bot.
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-pw-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let child = FakeChild()
        let spawns = SpawnCounter()
        let host = makeHost(children: { argv, _ in
            spawns.record(argv)
            return child
        })
        let botID = BotID()

        let opened = try host.perform(
            botID: botID, route: .playwrightLocal,
            kind: "bot_browser_open", action: "", ref: "", text: "",
            url: "https://a.test/home", appSupport: appSupport
        )
        XCTAssertEqual(opened["url"] as? String, "https://a.test/home")
        XCTAssertEqual(opened["title"] as? String, "Home")
        XCTAssertTrue((opened["content"] as? String ?? "").contains("### Page"))

        _ = try host.perform(
            botID: botID, route: .playwrightLocal,
            kind: "bot_browser_snapshot", action: "", ref: "", text: "",
            url: "", appSupport: appSupport
        )
        XCTAssertEqual(spawns.count, 1, "second call reuses the same child")
        XCTAssertEqual(child.calls.map(\.name), ["browser_navigate", "browser_snapshot"])

        // The pinned local argv is exactly what the host spawned, and the
        // profile directory was created for Chrome to use.
        let profile = BotBrowserPlaywrightHost.localProfileDirectory(appSupport: appSupport, botID: botID)
        XCTAssertEqual(
            spawns.argvs.first,
            BotBrowserPlaywrightHost.localArguments(npxPath: "/fake/npx", profileDirectory: profile.path)
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func test_hostGuestRouteSpawnsDockerExecArgv() throws {
        // WHY: docker bots must run Playwright INSIDE their guest, never a
        // host npx; the argv is the whole contract.
        let child = FakeChild()
        let spawns = SpawnCounter()
        let host = makeHost(children: { argv, _ in
            spawns.record(argv)
            return child
        })
        let botID = BotID()
        _ = try host.perform(
            botID: botID, route: .playwrightGuest,
            kind: "bot_browser_snapshot", action: "", ref: "", text: "",
            url: "", appSupport: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(
            spawns.argvs.first,
            BotBrowserPlaywrightHost.guestArguments(dockerPath: "/fake/docker", botID: botID)
        )
    }

    func test_hostToolErrorSurfacesVerbatimAndKeepsChild_transportErrorDropsIt() throws {
        // WHY: a bad ref must not kill a logged-in browser (tool error), but
        // a dead pipe must drop the child so the next call respawns.
        let child = FakeChild()
        let spawns = SpawnCounter()
        let host = makeHost(children: { argv, _ in
            spawns.record(argv)
            return child
        })
        let botID = BotID()
        let appSupport = FileManager.default.temporaryDirectory

        child.nextResponse = [
            "result": ["content": [["type": "text", "text": "Ref e9 not found"]], "isError": true],
        ]
        XCTAssertThrowsError(
            try host.perform(
                botID: botID, route: .playwrightGuest,
                kind: "bot_browser_act", action: "click", ref: "e9", text: "",
                url: "", appSupport: appSupport
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "Ref e9 not found")
        }
        XCTAssertEqual(child.terminateCount, 0, "tool error keeps the live browser")

        child.callError = BotBrowserPlaywrightBridgeError.invalid("Playwright browser exited unexpectedly.")
        XCTAssertThrowsError(
            try host.perform(
                botID: botID, route: .playwrightGuest,
                kind: "bot_browser_snapshot", action: "", ref: "", text: "",
                url: "", appSupport: appSupport
            )
        )
        XCTAssertEqual(child.terminateCount, 1, "transport error terminates")

        child.callError = nil
        child.nextResponse = FakeChild.pageResponse(url: "https://a.test", title: "A")
        _ = try host.perform(
            botID: botID, route: .playwrightGuest,
            kind: "bot_browser_snapshot", action: "", ref: "", text: "",
            url: "", appSupport: appSupport
        )
        XCTAssertEqual(spawns.count, 2, "dropped child respawns on the next call")
    }

    func test_handshakeFailure_respawnsOnceAndRetriesOnlyTheHandshake() throws {
        // WHY: a child that dies before the handshake is a dead pipe, so one respawn recovers without the user retrying.
        // The tool call is never replayed, so a click cannot run twice.
        let first = FakeChild()
        first.handshakeError = BotBrowserPlaywrightBridgeError.invalid("pipe closed")
        let second = FakeChild()
        let spawns = SpawnCounter()
        let host = makeHost(children: { argv, _ in
            spawns.record(argv)
            return spawns.count == 1 ? first : second
        })

        let result = try host.perform(
            botID: BotID(), route: .playwrightGuest,
            kind: "bot_browser_snapshot", action: "", ref: "", text: "",
            url: "", appSupport: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result["url"] as? String, "https://a.test/home")
        XCTAssertEqual(spawns.count, 2)
        XCTAssertEqual(first.terminateCount, 1)
        XCTAssertTrue(first.calls.isEmpty)
        XCTAssertEqual(second.calls.count, 1)
    }

    func test_handshakeFailureTwice_throwsTheOriginalErrorWithoutCallingTheTool() {
        // WHY: a second failure must surface the first real error, not a silent loop or a tool call on a dead child.
        let first = FakeChild()
        first.handshakeError = BotBrowserPlaywrightBridgeError.invalid("first")
        let second = FakeChild()
        second.handshakeError = BotBrowserPlaywrightBridgeError.invalid("second")
        let spawns = SpawnCounter()
        let host = makeHost(children: { argv, _ in
            spawns.record(argv)
            return spawns.count == 1 ? first : second
        })

        XCTAssertThrowsError(
            try host.perform(
                botID: BotID(), route: .playwrightGuest,
                kind: "bot_browser_snapshot", action: "", ref: "", text: "",
                url: "", appSupport: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "first")
        }
        XCTAssertEqual(spawns.count, 2)
        XCTAssertTrue(first.calls.isEmpty)
        XCTAssertTrue(second.calls.isEmpty)
    }

    func test_hostFallsBackToLastKnownPageWhenResponseHasNoPageLines() throws {
        // WHY: some act responses carry no Page section; blanking url/title
        // would zero bot_browser_get and confuse the login wait.
        let child = FakeChild()
        let host = makeHost(children: { _, _ in child })
        let botID = BotID()
        let appSupport = FileManager.default.temporaryDirectory

        _ = try host.perform(
            botID: botID, route: .playwrightLocal,
            kind: "bot_browser_open", action: "", ref: "", text: "",
            url: "https://a.test/home", appSupport: appSupport
        )
        child.nextResponse = [
            "result": ["content": [["type": "text", "text": "typed ok"]], "isError": false],
        ]
        let typed = try host.perform(
            botID: botID, route: .playwrightLocal,
            kind: "bot_browser_act", action: "type", ref: "e2", text: "hi",
            url: "", appSupport: appSupport
        )
        XCTAssertEqual(typed["url"] as? String, "https://a.test/home")
        XCTAssertEqual(typed["title"] as? String, "Home")
        XCTAssertEqual(typed["content"] as? String, "typed ok")
    }
}
