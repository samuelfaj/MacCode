import XCTest
import AppKit
import SwiftUI
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// Timing benches for SwiftUI work that repeats with no visible change.
/// Skipped unless `RC_PERF_RENDER_BENCH=1`, so normal runs stay fast. Each
/// bench warms once, then prints the median of `RC_PERF_SAMPLES` (default 7).
@MainActor
final class SurfacesRenderWorkPerfBenchTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_PERF_RENDER_BENCH"] == "1" else {
            throw XCTSkip("RC_PERF_RENDER_BENCH is not set")
        }
    }

    private func samples(_ name: String, unit: String, _ body: () throws -> Double) rethrows {
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        _ = try body()
        var values: [Double] = []
        for _ in 0..<count { values.append(try body()) }
        let median = values.sorted()[values.count / 2]
        let rendered = values.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=\(name) median_\(unit)=\(String(format: "%.2f", median)) samples_\(unit)=[\(rendered)]")
    }

    private func elapsedMs(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // MARK: - Agent App thread rail running set

    /// One rail body pass builds the running-id set over every filtered thread.
    /// A workspace rail is capped at `maxThreadsPerWorkspace` (20) on reload.
    func test_bench_threadRailRunningSet() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-rail-bench-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providers: [:])
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        for i in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            try threadRepo.upsert(AgentThread(workspaceId: workspaceID, title: "t\(i)", provider: .codex,
                                              model: "gpt-5.6-sol", status: .completed))
        }
        vm.reloadThreads()
        XCTAssertEqual(vm.filteredThreads.count, AgentThreadRepository.maxThreadsPerWorkspace)
        var sink = 0
        samples("agent.threadRail.runningSet.20threads.x100", unit: "ms") {
            elapsedMs {
                for _ in 0..<100 {
                    let runningThreadIds = railRunningThreadIds(vm)
                    sink &+= runningThreadIds.count
                }
            }
        }
        XCTAssertEqual(sink, 0)
    }

    /// Mirrors the expression the rail body evaluates (AgentAppSurface threadRail).
    /// Before the perf change it was a per-thread `isThreadStartingOrRunning` compactMap.
    private func railRunningThreadIds(_ vm: AgentAppViewModel) -> Set<AgentThreadID> {
        vm.startingOrRunningThreadIds(among: vm.filteredThreads)
    }

    // MARK: - Ultracode border

    /// Process CPU time (ms) spent in 1 s while a composer-sized border sits in a
    /// host that also lays out 300 transcript-like rows, like the Agent App window.
    private func borderCPUMsPerSecond(state: ControlActiveState, rows: Int = 300) -> Double {
        let view = VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { Text("transcript row \($0)").font(.body) }
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.black)
                .frame(width: 760, height: 120)
                .modifier(UltracodeBorder(active: true))
        }
        .padding(24)
        .environment(\.controlActiveState, state)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 820, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func cpuMs() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
        }
        let start = cpuMs()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let spent = cpuMs() - start
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return spent
    }

    func test_bench_ultracodeBorderCPUPerSecond() {
        for (label, state) in [("key", ControlActiveState.key), ("inactive", .inactive)] {
            samples("ultracode.border.cpuMsPerSecond.\(label)", unit: "ms") {
                borderCPUMsPerSecond(state: state)
            }
        }
        samples("ultracode.border.cpuMsPerSecond.keyBorderOnly", unit: "ms") {
            borderCPUMsPerSecond(state: .key, rows: 0)
        }
    }
}
