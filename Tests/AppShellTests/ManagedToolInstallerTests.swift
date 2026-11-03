import XCTest
@testable import AppShell

final class ManagedToolInstallerTests: XCTestCase {
    func test_releaseParsing_keepsOnlyHttpsAssets_andRejectsBadTags() throws {
        // WHY: the tag becomes a path component and the assets are downloaded;
        // a tag with "/" or a non-https asset must never be used.
        let json = #"{"tag_name":"v1.5.3","assets":[{"name":"SHA256SUMS","browser_download_url":"https://github.com/x/SHA256SUMS"},{"name":"evil","browser_download_url":"http://x/evil"}]}"#
        let release = try ManagedToolInstaller.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.tag, "v1.5.3")
        XCTAssertEqual(Array(release.assets.keys), ["SHA256SUMS"])
        XCTAssertThrowsError(try ManagedToolInstaller.parseRelease(Data(#"{"tag_name":"../x","assets":[]}"#.utf8)))
    }

    func test_expectedDigest_matchesOnlyTheExactAsset() {
        // WHY: an asset installs only when SHA256SUMS lists that exact file.
        let sums = "aa  mac-use-mcp-v1.5.3-macos-arm64.tar.gz\nbb  mac-use-skill-v1.5.3.tar.gz\n"
        XCTAssertEqual(ManagedToolInstaller.expectedDigest(sums: sums, asset: "mac-use-skill-v1.5.3.tar.gz"), "bb")
        XCTAssertNil(ManagedToolInstaller.expectedDigest(sums: sums, asset: "mac-use-mcp"))
    }

    func test_retry_transientFailureThenSuccess_succeedsWithoutUserAction() async throws {
        // WHY: a network blip during the background tool install must not leave the tool missing until next launch.
        var calls = 0
        var sleeps: [TimeInterval] = []
        let value = try await retryingTransientFailures(delays: [2, 5], sleep: { sleeps.append($0) }) {
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(sleeps, [2])
    }

    func test_retry_permanentFailureFailsImmediately() async {
        // WHY: a checksum mismatch or bad JSON never heals on retry; re-downloading it only delays the error.
        var calls = 0
        do {
            _ = try await retryingTransientFailures(delays: [2, 5], sleep: { _ in XCTFail("must not sleep") }) { () async throws -> String in
                calls += 1
                throw ManagedToolInstaller.Failure("checksum mismatch for mac-use-mcp")
            }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(calls, 1)
        }
    }

    func test_retry_persistentTransientFailureThrowsOriginalAfterAllAttempts() async {
        // WHY: after the bounded attempts the caller must see the same error it saw before retries existed.
        var calls = 0
        do {
            _ = try await retryingTransientFailures(delays: [2, 5], sleep: { _ in }) { () async throws -> String in
                calls += 1
                throw URLError(.networkConnectionLost)
            }
            XCTFail("expected throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
            XCTAssertEqual(calls, 3)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_retry_httpResultStatus429And5xxRetried_otherStatusesNot() async throws {
        // WHY: 429/5xx are server-side and recover; 404/403 are answers that stay the same.
        for (status, expectedCalls) in [(503, 3), (429, 3), (404, 1), (403, 1)] {
            var calls = 0
            _ = try await retryingTransientFailures(
                delays: [2, 5],
                sleep: { _ in },
                retryResult: { (code: Int) in isRetryableHTTPStatus(code) }
            ) { () async throws -> Int in
                calls += 1
                return status
            }
            XCTAssertEqual(calls, expectedCalls, "status \(status)")
        }
    }
}
