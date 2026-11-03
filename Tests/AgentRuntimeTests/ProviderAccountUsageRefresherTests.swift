import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

final class ProviderAccountUsageRefresherTests: XCTestCase {
    private final class GrokProbeWorkload: @unchecked Sendable {
        private let lock = NSLock()
        private var fetchCountStorage = 0
        private var checksum: UInt64 = 0

        var fetchCount: Int {
            lock.withLock { fetchCountStorage }
        }

        func fetchPayload() -> [String: Any] {
            // Deterministic CPU work stands in for JSON/network response handling.
            // Retain the checksum so the optimizer cannot discard the loop.
            var value: UInt64 = 0xcbf29ce484222325
            for index in 0..<20_000 {
                value = (value ^ UInt64(index)) &* 0x100000001b3
            }
            lock.withLock {
                fetchCountStorage += 1
                checksum ^= value
            }
            return [
                "config": [
                    "creditUsagePercent": 36.0,
                    "currentPeriod": [
                        "type": "USAGE_PERIOD_TYPE_WEEKLY",
                        "end": "2099-08-26T16:16:03Z"
                    ]
                ]
            ]
        }
    }

    private func processCPUTimeNanoseconds() -> UInt64 {
        var value = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func test_ptyTerminateDoesNotBlockOnZombieWait() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/AgentRuntime/ProviderAccountUsageRefresher.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("waitForZombie: false"),
            "Claude /usage PTY teardown must not pin overlapping refreshes on waitpid(0)"
        )
        XCTAssertTrue(
            source.contains("inFlightRefresh"),
            "concurrent refreshAccountUsage must coalesce onto one in-flight task"
        )
    }

    func test_claudeLimitRefreshNeverReadsClaudeCodeKeychain() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // The parser lives in its own file; both halves of the refresh path are audited.
        for path in [
            "Sources/AgentRuntime/ProviderAccountUsageRefresher.swift",
            "Sources/AgentRuntime/AssistantAccountUsageParser.swift"
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )

            XCTAssertFalse(
                source.contains("Claude Code-credentials") || source.contains("SecItemCopyMatching"),
                "checking Claude limits must use Claude's own CLI fallback instead of prompting for Keychain access (\(path))"
            )
        }
    }

    func test_codexParserPrefersWeeklyCodexLimitBucket() {
        let usage = AssistantAccountUsageParser.codex(from: [
            "rateLimits": [
                "primary": [
                    "usedPercent": 11,
                    "windowDurationMins": 300
                ]
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "secondary": [
                        "used_percent": 34,
                        "window_minutes": 10_080,
                        "resets_at": 1_781_138_445
                    ],
                    "primary": [
                        "usedPercent": 13,
                        "windowDurationMins": 300
                    ]
                ]
            ]
        ])

        XCTAssertEqual(usage?.provider, .codex)
        XCTAssertEqual(usage?.weeklyUsedPercent, 34)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 13)
        XCTAssertNotNil(usage?.weeklyResetsAtMs)
    }

    func test_codexParserReadsRawAppServerPrimarySecondaryShape() {
        let usage = AssistantAccountUsageParser.codex(from: [
            "primary": [
                "used_percent": 13,
                "window_minutes": 300,
                "resets_at": 1_780_769_381
            ],
            "secondary": [
                "used_percent": 34,
                "window_minutes": 10_080,
                "resets_at": 1_781_138_445
            ],
            "plan_type": "pro"
        ])

        XCTAssertEqual(usage?.provider, .codex)
        XCTAssertEqual(usage?.weeklyUsedPercent, 34)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 13)
        XCTAssertEqual(usage?.weeklyResetsAtMs, 1_781_138_445_000)
    }

    func test_claudeUsageTextParsesUsedAndRemainingPercentages() {
        let used = AssistantAccountUsageParser.claudeUsageText("Weekly usage 57% used")
        XCTAssertEqual(used?.provider, .claude)
        XCTAssertEqual(used?.weeklyUsedPercent, 57)
        XCTAssertEqual(used?.weeklyWindowDurationMinutes, 10_080)

        let remaining = AssistantAccountUsageParser.claudeUsageText("Subscription usage 67% remaining")
        XCTAssertEqual(remaining?.provider, .claude)
        XCTAssertEqual(remaining?.weeklyUsedPercent, 33)
        XCTAssertEqual(remaining?.weeklyWindowDurationMinutes, 10_080)
    }

    /// WHY: Claude Code headless `/usage` switched to one-line copy
    /// ("Current week (all models): 54% used"). Legacy weekly|subscription
    /// patterns missed it, so the usage rings left Claude at Used 0% while Codex/Grok
    /// rings updated and Claude Estimated save kept climbing.
    func test_claudeUsageTextParsesModernHeadlessCurrentWeekAndSession() {
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 58% used · resets Aug 5 at 10:10pm (America/Asuncion)
        Current week (all models): 54% used · resets Aug 9 at 11am (America/Asuncion)
        Current week (Fable): 1% used · resets Aug 9 at 10:59am (America/Asuncion)
        """
        let usage = AssistantAccountUsageParser.claudeUsageText(output)
        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 54,
                       "must prefer Current week (all models), not Fable-only or subscription noise")
        XCTAssertEqual(usage?.currentSessionUsedPercent, 58,
                       "session % must populate Today ring; bare 0 painted 'no session data'")
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
    }

    /// WHY: screen→text→screen recursion stack-overflowed the detached refresh
    /// (signal 10) on empty / partial / remaining-only strings.
    func test_claudeUsageParsersDoNotRecurseOnEmptyOrNoMatch() {
        XCTAssertNil(AssistantAccountUsageParser.claudeUsageText(""))
        XCTAssertNil(AssistantAccountUsageParser.claudeUsageScreen(""))
        XCTAssertNil(AssistantAccountUsageParser.claudeUsageText("no percentages here"))
        XCTAssertNil(AssistantAccountUsageParser.claudeUsageScreen("❯ waiting for input"))
        // Remaining-only still matches loose patterns without re-entering screen.
        let remaining = AssistantAccountUsageParser.claudeUsageText("Subscription usage 67% remaining")
        XCTAssertEqual(remaining?.weeklyUsedPercent, 33)
    }

    func test_grokBillingLogLineParsesCreditUsagePercent() {
        // WHY: the Grok usage ring was stuck on "No data" because account
        // refresh never read Grok's local billing snapshot (creditUsagePercent).
        let line = #"""
        {"ts":"2026-07-13T23:32:27.798Z","src":"shell","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":29.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-08T20:46:41.975270+00:00","end":"2026-07-15T20:46:41.975270+00:00"},"billingPeriodStart":"2026-07-08T20:46:41.975270+00:00","billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00"},"subscriptionTier":"SuperGrok Heavy"}}
        """#
        let usage = AssistantAccountUsageParser.grokBillingLogLine(line)
        XCTAssertEqual(usage?.provider, .grok)
        XCTAssertEqual(usage?.weeklyUsedPercent, 29)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertNotNil(usage?.weeklyResetsAtMs,
                        "billingPeriodEnd must become weeklyResetsAt so the card can show reset timing")
    }

    func test_grokFromBillingLogFile_picksNewestPercent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("unified.jsonl")
        let body = """
        {"msg":"noise","ctx":{}}
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":10.0,"billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00"}}}
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":42.5,"billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00"}}}
        """
        try body.write(to: log, atomically: true, encoding: .utf8)
        let usage = AssistantAccountUsageParser.grokFromBillingLogFile(at: log)
        XCTAssertEqual(usage?.weeklyUsedPercent, 42.5,
                       "must use the newest billing line so the purple ring matches live Grok credits")
    }

    /// WHY: production `~/.grok/logs/unified.jsonl` put 800KB+ of non-billing
    /// traffic between credit snapshots. The old 512KB tail window returned nil,
    /// partial refresh cleared Grok, and the rings showed Used 0% despite real
    /// SuperGrok usage (and non-zero Saved tokens for Grok).
    func test_grokFromBillingLogFile_findsPercentBeyondFormer512KBWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("unified.jsonl")

        let billing = #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":65.0,"billingPeriodEnd":"2026-07-22T20:46:41.975270+00:00"}}}"# + "\n"
        // ~700 KiB of noise after the only billing line — larger than the old
        // 512 KiB default, smaller than the new 4 MiB default.
        let noiseLine = #"{"msg":"tool_result","ctx":{"output":""}}"# + String(repeating: "x", count: 200) + "\n"
        var body = billing
        while body.utf8.count < 700 * 1024 {
            body += noiseLine
        }
        try body.write(to: log, atomically: true, encoding: .utf8)

        let withLegacyWindow = AssistantAccountUsageParser.grokFromBillingLogFile(
            at: log,
            maxBytes: 512 * 1024
        )
        XCTAssertNil(withLegacyWindow,
                     "regression fixture: 512KB window must miss a billing line buried under 700KB of noise")

        let withDefaultWindow = AssistantAccountUsageParser.grokFromBillingLogFile(at: log)
        XCTAssertEqual(withDefaultWindow?.provider, .grok)
        XCTAssertEqual(withDefaultWindow?.weeklyUsedPercent, 65,
                       "default scan window must still find creditUsagePercent past the old 512KB limit")
    }

    func test_grokBillingJSON_prefersGrokBuildProductPercentOverSharedCredits() {
        // WHY: Grok's Usage UI labels the weekly bar "Grok Build". Painting the
        // shared-pool percent (or 0% after a log miss) while SuperGrok shows 31%
        // is the complaint this probe exists to close.
        let payload: [String: Any] = [
            "config": [
                "creditUsagePercent": 10.0,
                "productUsage": [
                    ["product": "GrokChat"],
                    ["product": "Grok Build", "usagePercent": 31.0],
                    ["product": "Api", "usagePercent": 44.0]
                ],
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2099-08-26T16:16:03Z"
                ]
            ]
        ]
        let usage = AssistantAccountUsageParser.grokBillingJSON(payload)
        XCTAssertEqual(usage?.weeklyUsedPercent, 31)
        XCTAssertNotNil(usage?.weeklyResetsAtMs)
    }

    func test_grokBillingJSON_usesLiveCreditsAPIShapeWithoutLogMessage() {
        let payload: [String: Any] = [
            "config": [
                "creditUsagePercent": 36.0,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2099-08-26T16:16:03Z"
                ]
            ]
        ]
        let usage = AssistantAccountUsageParser.grokBillingJSON(payload)
        XCTAssertEqual(usage?.provider, .grok)
        XCTAssertEqual(usage?.weeklyUsedPercent, 36)
    }

    func test_grokAccessToken_prefersUnexpiredKeyFromIssuerMap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        let body: [String: Any] = [
            "https://auth.x.ai::old": [
                "key": "expired-token",
                "expires_at": "2020-01-01T00:00:00Z"
            ],
            "https://auth.x.ai::live": [
                "key": "live-token",
                "expires_at": "2099-01-01T00:00:00Z"
            ]
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: auth)
        XCTAssertEqual(
            AssistantAccountUsageParser.grokAccessToken(fromAuthFile: auth),
            "live-token",
            "must use the unexpired CLI bearer, never the expired sibling account"
        )
    }

    func test_fetchGrokUsage_prefersLiveCreditsAPIOverStaleLog() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::live": ["key": "test-token", "expires_at": "2099-01-01T00:00:00Z"]
        ]).write(to: auth)
        let log = dir.appendingPathComponent("unified.jsonl")
        try #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":10.0,"billingPeriodEnd":"2099-07-22T20:46:41.975270+00:00"}}}"#
            .write(to: log, atomically: true, encoding: .utf8)

        let refresher = ProviderAccountUsageRefresher(
            timeoutSeconds: 3,
            grokCreditsFetcher: { _, token in
                guard token == "test-token" else { return nil }
                return [
                    "config": [
                        "creditUsagePercent": 31.0,
                        "currentPeriod": [
                            "type": "USAGE_PERIOD_TYPE_WEEKLY",
                            "end": "2099-08-26T16:16:03Z"
                        ]
                    ]
                ]
            }
        )
        let usage = await refresher.grokAccountUsage(ProviderAccountUsageRefreshRequest(
            grokBillingLogURL: log,
            grokAuthFileURL: auth
        ))
        XCTAssertEqual(usage?.weeklyUsedPercent, 31,
                       "live credits API must beat a stale billing-log percent so Grok is not stuck at the last CLI snapshot")
    }

    func test_grokCreditsFetch_retriesOnceOnTransientNetworkError() async throws {
        // WHY: one dropped connection must not blank a provider's usage until the next periodic refresh.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::live": ["key": "test-token", "expires_at": "2099-01-01T00:00:00Z"]
        ]).write(to: auth)
        let payload = try JSONSerialization.data(withJSONObject: [
            "config": ["creditUsagePercent": 31.0, "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2099-08-26T16:16:03Z"]]
        ])
        UsageRetryStubProtocol.reset(results: [.failure(URLError(.networkConnectionLost)), .success(payload)])
        URLProtocol.registerClass(UsageRetryStubProtocol.self)
        defer { URLProtocol.unregisterClass(UsageRetryStubProtocol.self) }

        let usage = await ProviderAccountUsageRefresher(timeoutSeconds: 3).grokAccountUsage(ProviderAccountUsageRefreshRequest(
            grokBillingLogURL: dir.appendingPathComponent("missing.jsonl"),
            grokAuthFileURL: auth,
            grokCreditsAPIURL: URL(string: "https://usage.example.test/grok")!
        ))
        XCTAssertEqual(usage?.weeklyUsedPercent, 31)
        XCTAssertEqual(UsageRetryStubProtocol.count, 2)
    }

    func test_grokCreditsFetch_doesNotRetryPermanentFailure() async throws {
        // WHY: a non-network failure is not transient; retrying just repeats the same error.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::live": ["key": "test-token", "expires_at": "2099-01-01T00:00:00Z"]
        ]).write(to: auth)
        UsageRetryStubProtocol.reset(results: [.failure(URLError(.badURL))])
        URLProtocol.registerClass(UsageRetryStubProtocol.self)
        defer { URLProtocol.unregisterClass(UsageRetryStubProtocol.self) }

        _ = await ProviderAccountUsageRefresher(timeoutSeconds: 3).grokAccountUsage(ProviderAccountUsageRefreshRequest(
            grokBillingLogURL: dir.appendingPathComponent("missing.jsonl"),
            grokAuthFileURL: auth,
            grokCreditsAPIURL: URL(string: "https://usage.example.test/grok")!
        ))
        XCTAssertEqual(UsageRetryStubProtocol.count, 1)
    }

    func test_fetchGrokUsage_keepsLogWhenLiveCreditsAPIFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::live": ["key": "test-token", "expires_at": "2099-01-01T00:00:00Z"]
        ]).write(to: auth)
        let log = dir.appendingPathComponent("unified.jsonl")
        try #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":42.0,"billingPeriodEnd":"2099-07-22T20:46:41.975270+00:00"}}}"#
            .write(to: log, atomically: true, encoding: .utf8)

        let refresher = ProviderAccountUsageRefresher(
            timeoutSeconds: 3,
            grokCreditsFetcher: { _, _ in nil }
        )
        let usage = await refresher.grokAccountUsage(ProviderAccountUsageRefreshRequest(
            grokBillingLogURL: log,
            grokAuthFileURL: auth
        ))
        XCTAssertEqual(usage?.weeklyUsedPercent, 42,
                       "API miss must fall back to the billing log rather than recording 0%")
    }

    func test_microbench_periodicRefreshAvoidsDuplicateGrokProbe() async throws {
        // WHY: the production timer used to execute this complete Grok auth,
        // fetch and parse path twice per tick. Measure the exact eliminated work,
        // not a synthetic counter-only helper.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-periodic-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("grok-auth.json")
        try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::live": ["key": "test-token", "expires_at": "2099-01-01T00:00:00Z"]
        ]).write(to: auth)
        let codexAuth = directory.appendingPathComponent("codex-auth.json")
        try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "codex-token", "account_id": "acct-1"]
        ]).write(to: codexAuth)
        let claudeAuth = directory.appendingPathComponent("claude-auth.json")
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "claude-token"]
        ]).write(to: claudeAuth)
        let grokURL = URL(string: "https://perf.invalid/grok")!
        let codexURL = URL(string: "https://perf.invalid/codex")!
        let claudeURL = URL(string: "https://perf.invalid/claude")!

        let workload = GrokProbeWorkload()
        let refresher = ProviderAccountUsageRefresher(
            timeoutSeconds: 3,
            jsonAPIFetcher: { url, _ in
                switch url {
                case grokURL:
                    return workload.fetchPayload()
                case codexURL:
                    return [
                        "rate_limit": [
                            "secondary_window": [
                                "used_percent": 41,
                                "limit_window_seconds": 604_800
                            ]
                        ]
                    ]
                case claudeURL:
                    return ["seven_day": ["utilization": 26]]
                default:
                    return nil
                }
            }
        )
        let ticksPerSample = 20

        func measure(includeGrokInFullRefresh: Bool) async -> (wallMS: Double, cpuMS: Double, fetches: Int) {
            let request = ProviderAccountUsageRefreshRequest(
                grokAuthFileURL: auth,
                grokCreditsAPIURL: grokURL,
                claudeAuthFileURL: claudeAuth,
                claudeUsageAPIURL: claudeURL,
                codexAuthFileURL: codexAuth,
                codexUsageAPIURL: codexURL,
                includeGrok: includeGrokInFullRefresh
            )
            let fetchesBefore = workload.fetchCount
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = processCPUTimeNanoseconds()
            var invalidResults = 0
            for _ in 0..<ticksPerSample {
                async let dedicatedGrok = refresher.grokAccountUsage(request)
                async let fullRefresh = refresher.refreshAccountUsage(request)
                let (grok, usages) = await (dedicatedGrok, fullRefresh)
                if grok?.weeklyUsedPercent != 36
                    || usages.first(where: { $0.provider == .codex })?.weeklyUsedPercent != 41
                    || usages.first(where: { $0.provider == .claude })?.weeklyUsedPercent != 26
                    || usages.contains(where: { $0.provider == .grok }) != includeGrokInFullRefresh {
                    invalidResults += 1
                }
            }
            let cpuEnd = processCPUTimeNanoseconds()
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(invalidResults, 0)
            return (
                Double(wallEnd - wallStart) / 1_000_000,
                Double(cpuEnd - cpuStart) / 1_000_000,
                workload.fetchCount - fetchesBefore
            )
        }

        for _ in 0..<2 {
            _ = await measure(includeGrokInFullRefresh: true)
            _ = await measure(includeGrokInFullRefresh: false)
        }

        var beforeCPU: [Double] = []
        var afterCPU: [Double] = []
        var beforeWall: [Double] = []
        var afterWall: [Double] = []
        for sample in 0..<5 {
            let first = await measure(includeGrokInFullRefresh: sample.isMultiple(of: 2))
            let second = await measure(includeGrokInFullRefresh: !sample.isMultiple(of: 2))
            let before = sample.isMultiple(of: 2) ? first : second
            let after = sample.isMultiple(of: 2) ? second : first
            XCTAssertEqual(before.fetches, ticksPerSample * 2)
            XCTAssertEqual(after.fetches, ticksPerSample)
            beforeCPU.append(before.cpuMS)
            afterCPU.append(after.cpuMS)
            beforeWall.append(before.wallMS)
            afterWall.append(after.wallMS)
        }

        let beforeMedianCPU = median(beforeCPU)
        let afterMedianCPU = median(afterCPU)
        let improvement = (beforeMedianCPU - afterMedianCPU) / beforeMedianCPU * 100
        print("[perf-proof] tokenSaverPeriodicGrok before_cpu_ms=\(beforeCPU) after_cpu_ms=\(afterCPU) before_wall_ms=\(beforeWall) after_wall_ms=\(afterWall) median_before_cpu_ms=\(beforeMedianCPU) median_after_cpu_ms=\(afterMedianCPU) improvement_pct=\(improvement) probes_per_20_ticks=40->20")
        XCTAssertGreaterThan(improvement, 5,
                             "removing one complete Grok probe per periodic tick must clear the performance gate")
    }

    func test_claudeOAuthUsage_readsSevenDayPercentAndFiveHourSession() {
        let usage = AssistantAccountUsageParser.claudeOAuthUsage(from: [
            "five_hour": ["utilization": 12, "resets_at": "2099-08-21T22:00:00Z"],
            "seven_day": ["utilization": 57, "resets_at": "2099-08-26T11:00:00Z"]
        ])
        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 57)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 12)
        XCTAssertNotNil(usage?.weeklyResetsAtMs)
    }

    func test_claudeOAuthUsage_acceptsFractionalUtilization() {
        let usage = AssistantAccountUsageParser.claudeOAuthUsage(from: [
            "seven_day": ["utilization": 0.31]
        ])
        XCTAssertEqual(usage?.weeklyUsedPercent, 31)
    }

    /// Claude Code 2.1.258 stream-json `rate_limit_event` nests utilization under
    /// `unifiedWindows`. Without this mapping, live Claude turns never refresh
    /// account usage rings even though the CLI is streaming accurate percentages.
    func test_claudeFrom_readsUnifiedWindowsUtilization() {
        let usage = AssistantAccountUsageParser.claude(from: [
            "type": "rate_limit_event",
            "rate_limit_info": [
                "rateLimitType": "five_hour",
                "resetsAt": 1_788_368_400,
                "status": "allowed",
                "unifiedWindows": [
                    "five_hour": ["resetsAt": 1_788_368_400, "utilization": 0.58],
                    "seven_day": ["resetsAt": 1_788_703_200, "utilization": 0.30],
                    "seven_day_overage_included": ["resetsAt": 1_788_703_200, "utilization": 0.39]
                ]
            ]
        ])
        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 30)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 58)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.weeklyResetsAtMs, 1_788_703_200_000)
        XCTAssertEqual(usage?.currentSessionResetsAtMs, 1_788_368_400_000)
    }

    func test_claudeFrom_stillReadsLegacyPrimaryUsedPercent() {
        let usage = AssistantAccountUsageParser.claude(from: [
            "rate_limit_info": [
                "primary": [
                    "usedPercent": 57,
                    "windowDurationMins": 10_080,
                    "resetsAt": "2026-05-23T12:00:00Z"
                ]
            ]
        ])
        XCTAssertEqual(usage?.weeklyUsedPercent, 57)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
    }

    func test_claudeAccessToken_readsClaudeAiOauthObject() {
        let token = AssistantAccountUsageParser.claudeAccessToken(fromAuthObject: [
            "claudeAiOauth": ["accessToken": "claude-live-token"]
        ])
        XCTAssertEqual(token, "claude-live-token")
    }

    func test_fetchClaudeUsage_prefersOAuthAPIOverCLI() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("credentials.json")
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "claude-token"]
        ]).write(to: auth)

        let refresher = ProviderAccountUsageRefresher(
            timeoutSeconds: 3,
            jsonAPIFetcher: { _, headers in
                guard headers["Authorization"] == "Bearer claude-token" else { return nil }
                return ["seven_day": ["utilization": 26, "resets_at": "2099-08-26T11:00:00Z"]]
            }
        )
        let usages = await refresher.refreshAccountUsage(ProviderAccountUsageRefreshRequest(
            claudeBinary: dir.appendingPathComponent("missing-claude").path,
            claudeAuthFileURL: auth
        ))
        XCTAssertEqual(usages.first(where: { $0.provider == .claude })?.weeklyUsedPercent, 26,
                       "live oauth/usage must beat spawning claude -p /usage")
    }

    func test_codexWhamUsage_usesSecondaryWeeklyWindow() {
        let usage = AssistantAccountUsageParser.codexWhamUsage(from: [
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 11,
                    "limit_window_seconds": 18_000
                ],
                "secondary_window": [
                    "used_percent": 83,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_781_138_445
                ]
            ]
        ])
        XCTAssertEqual(usage?.provider, .codex)
        XCTAssertEqual(usage?.weeklyUsedPercent, 83)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 11)
        XCTAssertEqual(usage?.weeklyResetsAtMs, 1_781_138_445_000)
    }

    func test_fetchCodexUsage_prefersWhamHTTPOverAppServer() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-codex-wham-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "codex-token", "account_id": "acct-1"]
        ]).write(to: auth)

        let refresher = ProviderAccountUsageRefresher(
            timeoutSeconds: 3,
            jsonAPIFetcher: { _, headers in
                guard headers["Authorization"] == "Bearer codex-token",
                      headers["ChatGPT-Account-ID"] == "acct-1" else { return nil }
                return [
                    "rate_limit": [
                        "secondary_window": [
                            "used_percent": 41,
                            "limit_window_seconds": 604_800
                        ]
                    ]
                ]
            }
        )
        let usages = await refresher.refreshAccountUsage(ProviderAccountUsageRefreshRequest(
            codexBinary: dir.appendingPathComponent("missing-codex").path,
            codexAuthFileURL: auth
        ))
        XCTAssertEqual(usages.first(where: { $0.provider == .codex })?.weeklyUsedPercent, 41,
                       "live wham/usage must beat spawning codex app-server")
    }

    func test_claudeUsageScreenParsesInteractiveUsageDialog() {
        let output = """
        Settings  Status Config Usage Stats

        Current session
        █▌ 3% used
        Resets 4:50pm (America/Asuncion)

        Current week (all models)
        ████████████████████████████▍ 56% used
        Resets Jun 9 at 7am (America/Asuncion)

        Current week (Sonnet only)
        █▌ 3% used
        Resets Jun 9 at 7am (America/Asuncion)
        """

        let usage = AssistantAccountUsageParser.claudeUsageScreen(output)

        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 56)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 3)
    }

    func test_claudeUsageScreenParsesCompactedTTYText() {
        let output = """
        Currentweek(allmodels)
        ████████████████████████████▉ 58%used
        ResetsJun9at7am(America/Asuncion)

        Currentweek(Sonnetonly)
        █▌ 3%used
        """

        let usage = AssistantAccountUsageParser.claudeUsageScreen(output)

        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 58)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
    }

    func test_claudeUsageScreenStripsAnsiCursorControls() {
        let output = """
        \u{001B}[3GCurrent\u{001B}[11Gweek\u{001B}[16G(all\u{001B}[21Gmodels)
        \u{001B}[3G████████████████████████████▉\u{001B}[54G58%\u{001B}[58Gused
        \u{001B}[3GResets\u{001B}[10GJun\u{001B}[14G9
        """

        let usage = AssistantAccountUsageParser.claudeUsageScreen(output)

        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 58)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
    }

    /// WHY: the normal Claude text probe can fail even though the interactive
    /// usage screen is available. The fallback must then launch the prepared
    /// executable/environment through the PTY, parse that screen, and reap its
    /// owned child before returning so no `<defunct>` Claude process remains.
    func test_claudeUsageRefresh_fallsBackToPTYScreenAndReapsChild() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-usage-pty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("fake-claude")
        let headlessMarker = dir.appendingPathComponent("headless-ran")
        let ptyPIDFile = dir.appendingPathComponent("pty-pid")
        try #"""
        #!/bin/sh
        if [ "$1" = "-p" ]; then
          : > "$RC2_CLAUDE_HEADLESS_MARKER"
          printf 'headless usage unavailable\n'
          exit 1
        fi
        printf '%s\n' "$$" > "$RC2_CLAUDE_PTY_PID_FILE"
        printf '❯'
        while IFS= read -r line; do
          case "$line" in
            */usage*)
              printf '\nCurrent week (all models)\n████████████████████████████ 56%% used\n'
              ;;
            */exit*) exit 0 ;;
          esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let usages = await ProviderAccountUsageRefresher(timeoutSeconds: 3)
            .refreshAccountUsage(ProviderAccountUsageRefreshRequest(
                codexBinary: dir.appendingPathComponent("missing-codex").path,
                claudeBinary: script.path,
                grokBillingLogURL: dir.appendingPathComponent("missing-grok-billing-log"),
                cwd: dir.path,
                environment: [
                    "RC2_CLAUDE_HEADLESS_MARKER": headlessMarker.path,
                    "RC2_CLAUDE_PTY_PID_FILE": ptyPIDFile.path
                ]
            ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: headlessMarker.path),
                      "fixture must fail the headless probe before exercising the interactive PTY fallback")
        XCTAssertEqual(usages.first(where: { $0.provider == .claude })?.weeklyUsedPercent, 56,
                       "interactive /usage output must be parsed after the headless probe fails")

        let ptyPID = try XCTUnwrap(Int32(try String(contentsOf: ptyPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let killResult = kill(ptyPID, 0)
        let killError = errno
        XCTAssertEqual(killResult, -1,
                       "fallback child must be terminated before refresh returns")
        XCTAssertEqual(killError, ESRCH)
        var status: Int32 = 0
        let waitResult = waitpid(ptyPID, &status, WNOHANG)
        let waitError = errno
        XCTAssertEqual(waitResult, -1,
                       "the refresher must retain final waitpid ownership for its PTY child")
        XCTAssertEqual(waitError, ECHILD,
                       "the fallback child must be reaped rather than left as a zombie")
    }

    /// A fake `claude` that records each launch's arguments and prints the
    /// headless `/usage` line, or fails the headless probe when `failHeadless`.
    private func makeCountingClaude(in dir: URL, failHeadless: Bool = false) throws -> (script: URL, launches: URL) {
        let launches = dir.appendingPathComponent("launches")
        let script = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        echo "$*" >> '\(launches.path)'
        if [ "$1" = "-p" ] && [ "\(failHeadless)" = "false" ]; then
          printf 'Current week (all models): 12%% used\\n'
          exit 0
        fi
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, launches)
    }

    private func launchLines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func writeClaudeConfig(
        to url: URL,
        fetchedAt: Date,
        cacheAccount: String = "acct-1",
        currentAccount: String = "acct-1",
        weekly: Int = 15
    ) throws {
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["accountUuid": currentAccount],
            "cachedUsageUtilization": [
                "fetchedAtMs": Int(fetchedAt.timeIntervalSince1970 * 1000),
                "accountUuid": cacheAccount,
                "utilization": [
                    "five_hour": ["utilization": 4, "resets_at": "2099-08-21T22:00:00Z"],
                    "seven_day": ["utilization": weekly, "resets_at": "2099-08-26T11:00:00Z"]
                ]
            ]
        ]).write(to: url)
    }

    /// WHY: a periodic tick that may not launch the Claude CLI must not launch
    /// it, nor the interactive PTY: each launch is ~10 CPU-s and ~600 MB.
    func test_claudeCLIProbeDisallowed_launchesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-no-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try makeCountingClaude(in: dir)

        let usages = await ProviderAccountUsageRefresher(timeoutSeconds: 3)
            .refreshAccountUsage(ProviderAccountUsageRefreshRequest(
                codexBinary: dir.appendingPathComponent("missing-codex").path,
                claudeBinary: claude.script.path,
                allowClaudeCLIProbe: false,
                cwd: dir.path
            ))
        XCTAssertNil(usages.first { $0.provider == .claude })
        XCTAssertEqual(launchLines(claude.launches), [], "a skipped probe must not launch claude")
    }

    /// WHY: the PTY fallback is the expensive, zombie-prone path. Periodic
    /// refreshes forbid it even when they may run the headless probe.
    func test_claudeUsageScreenDisallowed_skipsThePTYAfterAFailedHeadlessProbe() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-no-pty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try makeCountingClaude(in: dir, failHeadless: true)

        let usages = await ProviderAccountUsageRefresher(timeoutSeconds: 3)
            .refreshAccountUsage(ProviderAccountUsageRefreshRequest(
                codexBinary: dir.appendingPathComponent("missing-codex").path,
                claudeBinary: claude.script.path,
                allowClaudeUsageScreen: false,
                cwd: dir.path
            ))
        XCTAssertNil(usages.first { $0.provider == .claude })
        let launches = launchLines(claude.launches)
        XCTAssertEqual(launches.count, 1, "only the headless probe may run")
        XCTAssertTrue(launches.first?.hasPrefix("-p ") == true)
    }

    /// WHY: every probe used to boot the user's MCP servers and plugin hooks
    /// (a dozen processes, an npm registry call) just to print usage.
    func test_claudeHeadlessProbeSkipsMCPServersAndHooks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try makeCountingClaude(in: dir)

        let usages = await ProviderAccountUsageRefresher(timeoutSeconds: 3)
            .refreshAccountUsage(ProviderAccountUsageRefreshRequest(
                codexBinary: dir.appendingPathComponent("missing-codex").path,
                claudeBinary: claude.script.path,
                cwd: dir.path
            ))
        XCTAssertEqual(usages.first { $0.provider == .claude }?.weeklyUsedPercent, 12)
        XCTAssertEqual(launchLines(claude.launches), [
            #"-p --output-format text --no-session-persistence --max-budget-usd 0.01 --strict-mcp-config --settings {"disableAllHooks":true} /usage"#
        ])
    }

    /// WHY: Claude Code answers `/usage` from its own cache in `~/.claude.json`
    /// while it is under 60 s old. Reading that cache gives the same answer as
    /// launching the CLI, without launching it.
    func test_freshClaudeCodeUsageCacheAnswersWithoutLaunchingTheCLI() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try makeCountingClaude(in: dir)
        let config = dir.appendingPathComponent(".claude.json")
        try writeClaudeConfig(to: config, fetchedAt: Date().addingTimeInterval(-5))

        let usages = await ProviderAccountUsageRefresher(timeoutSeconds: 3)
            .refreshAccountUsage(ProviderAccountUsageRefreshRequest(
                codexBinary: dir.appendingPathComponent("missing-codex").path,
                claudeBinary: claude.script.path,
                claudeUsageCacheURL: config,
                cwd: dir.path
            ))
        let usage = try XCTUnwrap(usages.first { $0.provider == .claude })
        XCTAssertEqual(usage.weeklyUsedPercent, 15)
        XCTAssertEqual(usage.currentSessionUsedPercent, 4)
        XCTAssertNotNil(usage.weeklyResetsAtMs)
        XCTAssertEqual(launchLines(claude.launches), [], "a fresh cache must not launch claude")
    }

    /// WHY: a cache older than Claude Code's own 60 s window, or stamped for
    /// another signed-in account, is not what `/usage` would print now.
    func test_staleOrForeignClaudeCodeUsageCacheIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-cache-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent(".claude.json")

        try writeClaudeConfig(to: config, fetchedAt: Date().addingTimeInterval(-61))
        XCTAssertNil(AssistantAccountUsageParser.claudeCachedUsage(fromConfigFile: config))

        try writeClaudeConfig(to: config, fetchedAt: Date(), cacheAccount: "acct-old")
        XCTAssertNil(AssistantAccountUsageParser.claudeCachedUsage(fromConfigFile: config),
                     "another account's usage must never paint this account's ring")

        try writeClaudeConfig(to: config, fetchedAt: Date())
        XCTAssertEqual(AssistantAccountUsageParser.claudeCachedUsage(fromConfigFile: config)?.weeklyUsedPercent, 15)
    }

    func test_liveAccountUsageRefresh_whenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_LIVE_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_LIVE_USAGE_TEST=1 to call local provider usage commands.")
        }

        let usages = await ProviderAccountUsageRefresher(timeoutSeconds: 18)
            .refreshAccountUsage(ProviderAccountUsageRefreshRequest(
                cwd: "/Users/samuelfajreldines/dev/empath",
                environment: [:]
            ))
        print("LIVE_USAGE", usages.map { "\($0.provider.rawValue):\($0.weeklyUsedPercent):\($0.currentSessionUsedPercent ?? -1)" }.joined(separator: ","))

        XCTAssertTrue(usages.contains(where: { $0.provider == .claude && $0.weeklyUsedPercent > 0 }))
        XCTAssertTrue(usages.contains(where: { $0.provider == .codex && $0.weeklyUsedPercent > 0 }))
    }
}

private final class UsageRetryStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var results: [Result<Data, Error>] = []
    private nonisolated(unsafe) static var requestCount = 0

    static func reset(results: [Result<Data, Error>]) {
        lock.withLock { self.results = results; requestCount = 0 }
    }

    static var count: Int { lock.withLock { requestCount } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "usage.example.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result: Result<Data, Error> = Self.lock.withLock {
            Self.requestCount += 1
            return Self.results.isEmpty ? .success(Data("{}".utf8)) : Self.results.removeFirst()
        }
        switch result {
        case .success(let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
