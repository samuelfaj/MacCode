import XCTest
import CoreModel
@testable import Surfaces

@MainActor
final class TerminalSurfaceRuntimeHealthTests: XCTestCase {
    private final class WriterMode: @unchecked Sendable {
        private let lock = NSLock()
        private var _draining = false
        func setDraining() { lock.lock(); _draining = true; lock.unlock() }
        var isDraining: Bool { lock.lock(); defer { lock.unlock() }; return _draining }
    }

    private final class CapturedInputHealth: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        func record(_ value: Bool) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var recordedValues: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    override func tearDown() {
        SurfaceRuntimeBus.shared.sink = nil
        super.tearDown()
    }

    func test_inputStallAndResume_publishRuntimeHealthTransitions() throws {
        let mode = WriterMode()
        let pump = TerminalInputPump(
            retryDelay: 1_000,
            maxWouldBlockWaitMicros: 1_000,
            writer: { data, offset in
                guard mode.isDraining else { return .wouldBlock }
                return .wrote(data.count - offset)
            }
        )
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "health",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }
        surface.installInputPumpForRuntimeHealthTests(pump, processAlive: true)

        let captured = CapturedInputHealth()
        let surfaceID = surface.descriptor.id
        SurfaceRuntimeBus.shared.sink = { id, health in
            guard id == surfaceID else { return }
            captured.record(health.inputAccepting)
        }

        XCTAssertEqual(pump.enqueue(Data("x".utf8)), .accepted)
        pump.drain()
        waitUntil("stall callback must publish input_accepting=false") {
            captured.recordedValues.contains(false)
        }

        mode.setDraining()
        usleep(20_000)
        pump.drain()
        waitUntil("resume callback must publish input_accepting=true") {
            captured.recordedValues.contains(false) && captured.recordedValues.last == true
        }

        XCTAssertEqual(captured.recordedValues, [false, true],
            "TerminalSurface must publish the mirror-facing input_accepting transition for stall then resume")
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 1, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }

    /// Only EAGAIN means the fork never started; other errno must fail at once.
    func test_ptySpawnRetry_onlyEAGAINRetriesWithBoundedDelays() {
        XCTAssertEqual(TerminalSurface.ptySpawnRetryDelay(attempt: 0, errno: EAGAIN), 0.1)
        XCTAssertEqual(TerminalSurface.ptySpawnRetryDelay(attempt: 1, errno: EAGAIN), 0.3)
        XCTAssertNil(TerminalSurface.ptySpawnRetryDelay(attempt: 2, errno: EAGAIN))
        XCTAssertNil(TerminalSurface.ptySpawnRetryDelay(attempt: 0, errno: ENOENT))
    }
}
