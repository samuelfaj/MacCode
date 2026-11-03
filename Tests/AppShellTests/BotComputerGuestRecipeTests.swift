import XCTest
import CoreModel

final class BotComputerGuestRecipeTests: XCTestCase {
    func test_recipeIsFirstPartyLinuxDesktop_notAlpineSleep() throws {
        // WHY: alpine/sleep would let Studio show Docker desktop without a
        // screen. The guest must be Xvfb + Chromium + interactive noVNC.
        let root = sourceURL("Sources/AppShell/Resources/ComputerGuest")
        let dockerfile = try String(contentsOf: root.appendingPathComponent("Dockerfile"), encoding: .utf8)
        let start = try String(contentsOf: root.appendingPathComponent("start.sh"), encoding: .utf8)
        let browser = try String(contentsOf: root.appendingPathComponent("launch-browser.sh"), encoding: .utf8)
        let embed = try String(contentsOf: root.appendingPathComponent("embed.html"), encoding: .utf8)
        XCTAssertTrue(dockerfile.lowercased().contains("debian"))
        XCTAssertFalse(dockerfile.lowercased().contains("alpine"))
        XCTAssertFalse(dockerfile.contains("CMD sleep"))
        XCTAssertTrue(start.contains("Xvfb"))
        XCTAssertTrue(start.lowercased().contains("fluxbox"))
        XCTAssertFalse(start.contains("viewonly") || start.contains("-viewonly"))
        XCTAssertTrue(start.contains("websockify"))
        XCTAssertTrue(browser.lowercased().contains("chromium"))
        XCTAssertTrue(browser.contains("--no-sandbox"))
        XCTAssertTrue(embed.contains("token"))
        XCTAssertTrue(embed.contains("view_only=0"))
    }

    func test_xvfbGeometryMatchesTheActCoordinateBounds() throws {
        // WHY: bot_computer_act bounds clicks/drags by BotComputerGuestSpec's screen
        // size. If start.sh's Xvfb geometry drifts, valid on-screen points get
        // rejected or off-screen points get clamped onto the wrong control.
        let start = try String(
            contentsOf: sourceURL("Sources/AppShell/Resources/ComputerGuest/start.sh"),
            encoding: .utf8
        )
        let geometry = "\(BotComputerGuestSpec.screenWidth)x\(BotComputerGuestSpec.screenHeight)x24"
        XCTAssertTrue(start.contains("Xvfb :1 -screen 0 \(geometry) "), "start.sh must start Xvfb at \(geometry)")
    }

    func test_startClearsTheChromiumProfileLockBeforeLaunchingTheBrowser() throws {
        // WHY: the profile is on the persisted home bind, and a recreated
        // container has a new hostname. Chromium then reads the old lock as "in
        // use on another computer" and never opens (proved on r4 and r5), which
        // also leaves nothing on CDP 9222 for the in-guest Playwright MCP.
        let start = try String(
            contentsOf: sourceURL("Sources/AppShell/Resources/ComputerGuest/start.sh"),
            encoding: .utf8
        )
        let clear = try XCTUnwrap(start.range(of: "\"$HOME/.browser-profiles/chromium/SingletonLock\""))
        let launch = try XCTUnwrap(start.range(of: "/opt/remotecode-computer/launch-browser.sh"))
        XCTAssertTrue(start[..<clear.lowerBound].hasSuffix("rm -f "))
        XCTAssertLessThan(clear.lowerBound, launch.lowerBound)
    }

    func test_browserSurvivesGPUProcessKillsAndRestoresTheSession() throws {
        // WHY: when the Docker VM runs low on memory the kernel kills a separate
        // GPU process; after three kills Chromium aborts ("GPU process isn't
        // usable") and reopened on about:blank, so tabs and session-cookie
        // logins looked unsaved. In-process GPU leaves nothing to kill, and the
        // restored session brings tabs and session cookies back after a restart.
        let root = sourceURL("Sources/AppShell/Resources/ComputerGuest")
        let browser = try String(contentsOf: root.appendingPathComponent("launch-browser.sh"), encoding: .utf8)
        let dockerfile = try String(contentsOf: root.appendingPathComponent("Dockerfile"), encoding: .utf8)
        for flag in ["--in-process-gpu", "--disable-dev-shm-usage", "--restore-last-session", "--hide-crash-restore-bubble"] {
            XCTAssertTrue(browser.contains("    \(flag) \\\n"), "launch-browser.sh must pass \(flag)")
        }
        XCTAssertFalse(browser.contains("about:blank"), "a start URL would replace the restored tabs")
        XCTAssertTrue(dockerfile.contains("/etc/chromium/policies/recommended"))
        XCTAssertTrue(dockerfile.contains(#"{"RestoreOnStartup": 1, "HighEfficiencyModeEnabled": true}"#))
    }

    func test_startRestartsAHungBrowserNotOnlyAnExitedOne() throws {
        // WHY: a hung Chromium never exits, so the restart loop alone would
        // leave the bot without a browser or CDP for Playwright forever.
        let start = try String(
            contentsOf: sourceURL("Sources/AppShell/Resources/ComputerGuest/start.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(start.contains("curl -fsS -m 5 -o /dev/null http://127.0.0.1:9222/json/version"))
        XCTAssertTrue(start.contains(#"kill -KILL "$browser""#))
        XCTAssertFalse(start.contains("\nwait -n"), "a browser exit must never end the container")
    }

    func test_recipeChangeBumpsTheImageRevision() throws {
        // WHY: a bot's own image is reused while its revision label matches, so
        // a browser fix that does not bump the revision never reaches existing bots.
        let root = sourceURL("Sources/AppShell/Resources/ComputerGuest")
        XCTAssertEqual(BotComputerGuestSpec.recipeRevision, "9")
        XCTAssertEqual(
            BotComputerGuestSpec.recipeDigest(context: root),
            "ce099759eac024c6217fdbc2e873855201c9efd609c94f7a250d0512655b6777",
            "recipe files changed: bump recipeRevision, then update this digest"
        )
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
