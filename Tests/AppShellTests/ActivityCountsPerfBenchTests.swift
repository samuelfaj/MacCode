import XCTest
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

/// Timing benches for the Activity count refresh over a read-only copy of a real
/// database. Skipped unless `RC_PERF_DB_COPY` names one, so CI never depends on
/// private data. Each bench warms once, then prints the median of `RC_PERF_SAMPLES`
/// (default 7) runs.
final class ActivityCountsPerfBenchTests: XCTestCase {
    private func openService() throws -> ActivityService {
        guard let path = ProcessInfo.processInfo.environment["RC_PERF_DB_COPY"], !path.isEmpty else {
            throw XCTSkip("RC_PERF_DB_COPY is not set")
        }
        let db = try SQLiteDB(path: path, readonly: true)
        return ActivityService(db: db, readDB: db)
    }

    /// Runs off the main thread, like the read gateway does in the app, so the
    /// main-thread wait diagnostics in SQLiteDB do not inflate the samples.
    private func bench(_ name: String, _ body: @escaping () throws -> Void) throws {
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        var samples: [Double] = []
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "activity-counts-bench").async {
            do {
                try body()
                for _ in 0..<count {
                    let start = DispatchTime.now().uptimeNanoseconds
                    try body()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
            } catch { failure = error }
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
        let median = samples.sorted()[samples.count / 2]
        let rendered = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=\(name) median_ms=\(String(format: "%.2f", median)) samples_ms=[\(rendered)]")
    }

    /// The Pet/sidebar count refresh as it ran before the counts-only path: a one-item
    /// page through the full projection, then the JSONValue round trip.
    func test_bench_activityListLimitOneWithRoundTrip() throws {
        let service = try openService()
        try bench("activity.listLimit1RoundTrip") {
            let value = try service.list(["limit": .number(1)])
            _ = try ActivityPage.makeJSONDecoder().decode(ActivityPage.self, from: JSONEncoder().encode(value))
        }
    }

    /// The Pet Live Activity page: the call that held the shared read connection for
    /// seconds while it decoded every run's checkpoint files.
    func test_bench_activityListPageOfFifty() throws {
        let service = try openService()
        try bench("activity.listLimit50") {
            _ = try service.list(["section": .string("all"), "limit": .number(50)])
        }
    }

    /// Both paths alternated sample by sample, so machine load hits them equally.
    func test_bench_interleavedListVersusCountsOnly() throws {
        let service = try openService()
        var useCounts = false
        var list: [Double] = [], counts: [Double] = []
        try bench("activity.interleavedPair") {
            useCounts.toggle()
            let start = DispatchTime.now().uptimeNanoseconds
            if useCounts {
                _ = try service.counts()
            } else {
                let value = try service.list(["limit": .number(1)])
                _ = try ActivityPage.makeJSONDecoder().decode(ActivityPage.self, from: JSONEncoder().encode(value))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if useCounts { counts.append(elapsed) } else { list.append(elapsed) }
        }
        for (name, samples) in [("interleaved.listLimit1RoundTrip", list), ("interleaved.countsOnly", counts)] {
            let warmed = Array(samples.dropFirst())
            let median = warmed.sorted()[warmed.count / 2]
            print("PERF_BENCH name=\(name) median_ms=\(String(format: "%.2f", median)) samples_ms=[\(warmed.map { String(format: "%.2f", $0) }.joined(separator: ","))]")
        }
    }

    /// The same refresh through the counts-only path the Pet and sidebar now use.
    func test_bench_activityCountsOnly() throws {
        let service = try openService()
        try bench("activity.countsOnly") {
            _ = try service.counts()
        }
    }
}
