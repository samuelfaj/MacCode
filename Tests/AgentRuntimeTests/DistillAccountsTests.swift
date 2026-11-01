import XCTest
@testable import AgentRuntime

final class DistillAccountsTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var log: URL!
    private var pidFile: URL!
    private var script: URL!

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillAccountsTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        log = root.appendingPathComponent("argv.log")
        pidFile = root.appendingPathComponent("pid")
        script = root.appendingPathComponent("distill")
        let body = """
        #!/bin/sh
        echo "argv: $*" >> "$FAKE_LOG"
        echo "home: $DISTILL_HOME" >> "$FAKE_LOG"
        if [ "$FAKE_MODE" = fail ]; then
          echo "noise" >&2; echo "boom: no browser   " >&2; echo "" >&2; exit 3
        fi
        if [ "$FAKE_MODE" = old ]; then
          echo "error: unrecognized subcommand 'accounts'" >&2
          echo "For more information, try --help." >&2; exit 2
        fi
        if [ "$FAKE_MODE" = junk ]; then echo '{}'; exit 0; fi
        if [ "$2" = login ]; then
          echo "Signing in..." >&2
          echo "  https://example.com/auth?x=1" >&2
          echo "  https://example.com/second" >&2
          if [ "$FAKE_MODE" = hang ]; then echo $$ > "$FAKE_PID"; exec sleep 30; fi
        fi
        case "$*" in
          "accounts login legacy-grok") echo '{"https://accounts.x.ai/sign-in":{"key":"k"}}' > "$DISTILL_HOME/auth.json";;
          "accounts login legacy-chatgpt") echo '{"tokens":{"access_token":"t"}}' > "$DISTILL_HOME/codex-auth.json";;
          "accounts login legacy-claude") echo '{"access_token":"t"}' > "$DISTILL_HOME/claude-auth.json";;
          "accounts login legacy-openrouter") echo '{"key":"k"}' > "$DISTILL_HOME/openrouter-auth.json";;
          "accounts logout legacy-grok") rm -f "$DISTILL_HOME/auth.json";;
          "accounts logout legacy-chatgpt") rm -f "$DISTILL_HOME/codex-auth.json";;
          "accounts logout legacy-claude") rm -f "$DISTILL_HOME/claude-auth.json";;
          "accounts logout legacy-openrouter") rm -f "$DISTILL_HOME/openrouter-auth.json";;
        esac
        echo '{"ok":true}'
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeAccounts(mode: String = "ok") -> DistillAccounts {
        DistillAccounts(home: home, binaryPath: script.path,
            environment: ["PATH": "/usr/bin:/bin", "FAKE_MODE": mode, "FAKE_LOG": log.path, "FAKE_PID": pidFile.path],
            openURL: { _ in })
    }

    private func logLines() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func write(_ json: String, to name: String) throws {
        try json.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func connected(_ accounts: DistillAccounts) -> [DistillAccountProvider: Bool] {
        Dictionary(uniqueKeysWithValues: accounts.statuses().map { ($0.provider, $0.connected) })
    }

    // MARK: statuses

    func test_statuses_missingFilesAreDisconnectedInAllCasesOrder() {
        let statuses = makeAccounts().statuses()
        XCTAssertEqual(statuses.map(\.provider), DistillAccountProvider.allCases)
        XCTAssertTrue(statuses.allSatisfy { !$0.connected })
    }

    func test_statuses_emptyOrBlankCredentialsAreDisconnected() throws {
        try write("", to: "auth.json")
        try write(#"{"tokens":{"access_token":"  "}}"#, to: "codex-auth.json")
        try write(#"{"access_token":""}"#, to: "claude-auth.json")
        try write(#"{"key":" "}"#, to: "openrouter-auth.json")
        XCTAssertTrue(connected(makeAccounts()).values.allSatisfy { !$0 })
    }

    func test_statuses_corruptAndApiKeyOnlyGrokAreDisconnected() throws {
        try write("not json", to: "auth.json")
        XCTAssertEqual(connected(makeAccounts())[.grok], false)
        try write(#"{"xai::api_key":{"key":"xai-123"}}"#, to: "auth.json")
        XCTAssertEqual(connected(makeAccounts())[.grok], false)
    }

    func test_statuses_validFilesAreConnected() throws {
        try write(#"{"xai::api_key":{"key":"ignored"},"https://accounts.x.ai/sign-in":{"key":"k","email":"grok@example.com"}}"#, to: "auth.json")
        try write(#"{"tokens":{"access_token":"t"}}"#, to: "codex-auth.json")
        try write(#"{"access_token":"t","email":"claude@example.com"}"#, to: "claude-auth.json")
        try write(#"{"key":"sk-or"}"#, to: "openrouter-auth.json")
        let statuses = makeAccounts().statuses()
        XCTAssertTrue(statuses.allSatisfy(\.connected))
        XCTAssertEqual(statuses.first { $0.provider == .grok }?.email, "grok@example.com")
        XCTAssertEqual(statuses.first { $0.provider == .claude }?.email, "claude@example.com")
        XCTAssertNil(statuses.first { $0.provider == .chatgpt }?.email)
        XCTAssertNil(statuses.first { $0.provider == .openrouter }?.email)
    }

    // MARK: CLI login / logout

    func test_login_runsProviderArgvWithDistillHomeAndReportsFirstURL() async throws {
        let expected: [(DistillAccountProvider, String)] = [
            (.grok, "accounts login legacy-grok"), (.chatgpt, "accounts login legacy-chatgpt"),
            (.claude, "accounts login legacy-claude"), (.openrouter, "accounts login legacy-openrouter"),
        ]
        for (provider, argv) in expected {
            try? FileManager.default.removeItem(at: log)
            let urls = Box<URL>()
            let accounts = makeAccounts()
            try await accounts.login(provider) { urls.add($0) }
            XCTAssertEqual(logLines(), ["argv: \(argv)", "home: \(home.path)"], "\(provider)")
            XCTAssertEqual(urls.all.map(\.absoluteString), ["https://example.com/auth?x=1"], "\(provider)")
            XCTAssertEqual(connected(accounts)[provider], true, "\(provider)")
        }
    }

    func test_logout_runsProviderArgvAndRemovesOnlyThatProvider() async throws {
        try write(#"{"https://accounts.x.ai/sign-in":{"key":"k"}}"#, to: "auth.json")
        try write(#"{"tokens":{"access_token":"t"}}"#, to: "codex-auth.json")
        try write(#"{"access_token":"t"}"#, to: "claude-auth.json")
        try write(#"{"key":"fixture"}"#, to: "openrouter-auth.json")
        let accounts = makeAccounts()
        try await accounts.logout(.chatgpt)
        XCTAssertEqual(logLines(), ["argv: accounts logout legacy-chatgpt", "home: \(home.path)"])
        XCTAssertEqual(connected(accounts)[.chatgpt], false)
        XCTAssertEqual(connected(accounts)[.grok], true)
        XCTAssertEqual(connected(accounts)[.claude], true)
        XCTAssertEqual(connected(accounts)[.openrouter], true)
        try await accounts.logout(.claude)
        try await accounts.logout(.grok)
        try await accounts.logout(.openrouter)
        XCTAssertEqual(logLines().filter { $0.hasPrefix("argv:") },
                       ["argv: accounts logout legacy-chatgpt", "argv: accounts logout legacy-claude", "argv: accounts logout legacy-grok", "argv: accounts logout legacy-openrouter"])
        XCTAssertTrue(connected(accounts).values.allSatisfy { !$0 })
    }

    func test_login_failureUsesLastNonEmptyStderrLine() async {
        do {
            try await makeAccounts(mode: "fail").login(.claude) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .failed("boom: no browser"))
        }
    }

    func test_logout_failureUsesLastNonEmptyStderrLine() async {
        do {
            try await makeAccounts(mode: "fail").logout(.grok)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .failed("boom: no browser"))
        }
    }

    func test_login_cancellationTerminatesChildAndThrowsCancelled() async throws {
        let accounts = makeAccounts(mode: "hang")
        let task = Task { try await accounts.login(.chatgpt) { _ in } }
        let pid = try await waitForPID()
        XCTAssertEqual(kill(pid, 0), 0, "child should be running before cancel")
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .cancelled)
        }
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "child must be terminated")
    }

    private func waitForPID() async throws -> pid_t {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("fake child never started")
    }

    func test_oldCLIRequiresUpdateWithoutLegacyFallback() async {
        do {
            try await makeAccounts(mode: "old").login(id: "work") { _ in }
            XCTFail("unsupported CLI must fail")
        } catch { XCTAssertEqual(error as? DistillAccountError, .updateRequired) }
        XCTAssertEqual(logLines().first, "argv: accounts login work")
    }

    /// A wrong binary (e.g. a leftover test stub in `cli.distill.path`) must name
    /// itself instead of telling the user to update a Distill that is current.
    func test_unreadableResponseNamesBinaryInsteadOfRequiringUpdate() async {
        do {
            _ = try await makeAccounts(mode: "junk").loadRouting()
            XCTFail("unreadable response must fail")
        } catch {
            XCTAssertNotEqual(error as? DistillAccountError, .updateRequired)
            XCTAssertTrue(error.localizedDescription.contains(script.path), error.localizedDescription)
        }
    }

    func test_namedMetadataProbeKeepsSameProviderIdentitiesAndRejectsSymlink() throws {
        let records = [
            DistillAccountStatus(provider: .claude, connected: false, id: "one", label: "One", legacy: false),
            DistillAccountStatus(provider: .claude, connected: false, id: "two", label: "Two", legacy: false),
        ]
        let registry = DistillAccountRegistry(version: 1, accounts: records, routing: DistillAutoRouting())
        try JSONEncoder().encode(registry).write(to: home.appendingPathComponent("accounts.json"))
        for id in ["one", "two"] {
            let folder = home.appendingPathComponent("accounts/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"access_token":"fixture"}"#.utf8).write(to: folder.appendingPathComponent("claude-auth.json"))
        }
        XCTAssertEqual(makeAccounts().statuses().filter(\.connected).map(\.id), ["one", "two"])
        let one = home.appendingPathComponent("accounts/one")
        try FileManager.default.removeItem(at: one)
        try FileManager.default.createSymbolicLink(at: one, withDestinationURL: home.appendingPathComponent("accounts/two"))
        XCTAssertEqual(makeAccounts().statuses().filter(\.connected).map(\.id), ["two"])
    }

    func test_realCLIAccountAndRoutingContractWithoutCredentials() async throws {
        guard let binary = ProcessInfo.processInfo.environment["DISTILL_ACCOUNTS_TEST_BINARY"] else {
            throw XCTSkip("Controller supplies DISTILL_ACCOUNTS_TEST_BINARY for the actual CLI contract proof")
        }
        let accounts = DistillAccounts(home: home, binaryPath: binary,
            environment: ["HOME": root.path, "GROK_HOME": home.path, "PATH": "/usr/bin:/bin",
                "RC2_DISABLE_MANAGED_DISTILL_RECONCILE": "1", "GROK_DISABLE_AUTOUPDATER": "1",
                "GROK_TELEMETRY_ENABLED": "false", "GROK_TELEMETRY_MIXPANEL_ENABLED": "false",
                "GROK_TELEMETRY_TRACE_UPLOAD": "false", "GROK_FEEDBACK_ENABLED": "false",
                "GROK_INSTRUMENTATION": "disabled", "OTEL_SDK_DISABLED": "true"],
            openURL: { _ in XCTFail("No login/browser is allowed in this proof") })
        try await accounts.add(id: "one", provider: .claude, label: "One")
        try await accounts.add(id: "two", provider: .claude, label: "Two")
        try await accounts.rename(id: "one", label: "Renamed")
        let state = try await accounts.loadState()
        XCTAssertEqual(state.accounts.filter { !$0.legacy }.map(\.id), ["one", "two"])
        XCTAssertEqual(state.accounts.first { $0.id == "one" }?.label, "Renamed")
        XCTAssertTrue(state.accounts.allSatisfy { !$0.connected })
        let route = DistillAutoRouting(enabled: false, strategy: .highestRemaining,
            options: [DistillAutoOption(id: "route", accountID: "two", mainModel: "fixture-main")])
        try await accounts.saveRouting(route)
        let saved = try await accounts.loadRouting()
        XCTAssertEqual(saved, route)
        try await accounts.remove(id: "one")
        let after = try await accounts.loadState()
        XCTAssertEqual(after.accounts.filter { !$0.legacy }.map(\.id), ["two"])
        XCTAssertEqual(after.routing, route)
    }

    func test_quotaDecodesRFC3339AndRetainsUnknownAsNull() throws {
        let data = Data(#"{"account_id":"work","checked_at":"2026-10-12T18:58:45.174778Z","fetched_at":null,"status":"unavailable","remaining_percent":null,"detail":null}"#.utf8)
        let quota = try JSONDecoder().decode(DistillAccountQuota.self, from: data)
        XCTAssertEqual(quota.accountID, "work")
        XCTAssertNotNil(DistillHostCredentialRefresher.parseDate(quota.checkedAt))
        XCTAssertNil(quota.remainingPercent)
        XCTAssertNil(quota.fetchedAt)
    }
}
