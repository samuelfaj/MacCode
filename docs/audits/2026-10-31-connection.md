# iOS–macOS connection resilience audit

## Scope and revisions

- Host baseline: `b1fe5a2fd755f6376b1878e3ba9e9adfe0eba229`.
- iOS baseline: `b849ecb4fd0cc12f6f52c91a6427c555330bf1e1` (MR !115 already merged).
- Previous general macOS audit PR #57 is separate and is not included in this proposal.

Read-only inspection covered recovery ownership, cold/pinned connection, path transitions, direct/relay racing, stream startup, baseline/catch-up, HTTP GET retry/cancellation, listener leases, Noise handshake, relay registration, mux cleanup and local HTTP boundaries. This is bounded evidence, not a claim that all possible connection defects have been eliminated.

## Confirmed defect: blocked ping disabled registration timeout

`RelayHostClient.serveHost` awaited the ping send before checking receive liveness in the same task. A half-open WebSocket whose send suspended indefinitely also suspended the registration/open and receive deadline. The Mac could remain unavailable to the iPhone without advancing the reconnect loop.

The fix keeps ping emission and receive watchdog in independent tasks. Both are cancelled when the serving scope exits. A failed ping closes its socket rather than silently retiring the only liveness task. The watchdog closes a non-responsive socket even when send never returns, allowing the existing reconnect/backoff loop to register a replacement. Authorization, Noise, device trust, request replay and retry policy are unchanged.

`testStalledPingCannotBlockHostOpenDeadline` drives the real client with a socket whose text send waits until closure. It failed on the original implementation (`closeCode` remained nil) and passed after the fix. `testStalledRegistrationIsRetiredAndNextSocketConnects` verifies exactly one replacement registration restores connectivity. Existing tests retain idle receive deadline, auth backoff, account refresh after restart, revocation, encrypted HTTP/WebSocket transport, blocked output and stream cleanup checks.

## Rejected candidate: remote CLOSE leaks mux stream slots

A review candidate proposed removing an inner immediately on remote CLOSE. Actual code finishes its inbound queue and lets the local writer drain buffered response bytes before `finish` removes the inner and closes the local connection. Immediate cancellation would risk losing response bytes.

The new iOS regression sends 257 remote rejections (more than the 256-stream limit), then receives a successful HTTP response on the same single Noise session. It passed without changing production iOS transport. This preserves the working ordering boundary instead of patching an unsupported leak.

## Verification

- Host focused connection suite: 86 tests executed, 4 conditional skips, zero failures, native Swift build through the repository sandbox runner.
- iOS focused connection suite: 66 tests executed, zero failures, exclusive iPhone 17 / iOS 26.5 simulator. Includes real loopback sockets/Noise mux, failed-open holdoff, lease replacement, hard attempt deadlines, recovery ownership, event replay exactly once, hung RPC timeout/admission cleanup, and refusal to blindly resend an ambiguous mutation.
- Isolated debug product packaged and launched successfully; process listeners were only `127.0.0.1:18218` and `[::1]:18218`, `remote_access_enabled=0`, independent App Support/database, no copied personal credentials.
- Independent source review found no blocker in the scoped fix and explicitly rejected the unsupported iOS mux leak. The reviewer did not run tests.
- The four opt-in snapshot measurement tests also passed when enabled: 180 synthetic threads, five warmups and fifteen samples per scenario. Idle snapshot p50 99.017 ms / p95 102.912 ms; concurrent callers 30/30 successful; title/thread-update load 15/15 successful. These are local absolute measurements, not a before/after speedup claim.
- Native iOS pairing and actual Mac process restart/recovery journey passed: one test, zero skips/failures, 48.385 seconds. It pairs with the real isolated host, opens a host-owned thread, requests the exact debug process restart, then sees a new host-owned thread without a manual reconnect. Host discovery boot epoch advances while server identity and database remain the same.
- Earlier native attempts are retained rather than counted as passes: obsolete default-Home navigation; external restart monitor signalling process launch before HTTP readiness; and restored workspace detail hiding the Home-only test marker. The test now returns from restored detail to Home, opens Workspaces and Agent App explicitly, and captures hierarchy on readiness failures. The restart monitor waits for actual discovery response. Every original readiness and before/after host-state assertion remains.

No release, personal-phone installation, public relay deployment, live cellular/Wi-Fi handover, physical-device battery or universal performance claim. Local transport integration is not evidence of deployed-relay reachability. Only the focused suites and native journey above were run for this connection delta; the full unrelated macOS/iOS test inventories were not rerun.
