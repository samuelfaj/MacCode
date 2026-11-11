import Foundation
import Combine
import CoreModel
import SocketServer
import RemoteCodeTreaty

/// Per-thread Distill `/loop` state, persisted so the sidebar/iOS stay honest across relaunch.
// ponytail: a JSON file instead of a DB column; upgrade path = an `agent_threads` column.
@MainActor
public final class DistillLoopStore: ObservableObject {
    public static let fileName = "distill-loops.json"
    public static let resumeWaitingReason = L("Waiting for the agent session to resume")

    @Published public private(set) var snapshot: [AgentThreadID: [DistillLoopState]]

    private let fileURL: URL
    private let bus: EventBus

    /// `directory` is the app-support root. Loops still marked active were owned by
    /// the previous process, so they load as paused until a session resumes.
    public init(directory: URL, bus: EventBus = .shared) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.bus = bus
        var loaded = Self.load(from: fileURL)
        var changed = false
        for (thread, loops) in loaded {
            loaded[thread] = loops.map { loop in
                guard loop.state == .active else { return loop }
                changed = true
                var paused = loop
                paused.state = .paused
                paused.pausedReason = Self.resumeWaitingReason
                paused.nextFireAt = nil
                return paused
            }
        }
        self.snapshot = loaded
        if changed { save() }
    }

    /// A paused loop can be resumed whatever the reason text says.
    public static func resumable(_ loop: DistillLoopState) -> Bool { loop.state == .paused }

    public func resumableThreadIDs() -> [AgentThreadID] {
        snapshot.filter { $0.value.contains(where: Self.resumable) }.keys.sorted { $0.value.uuidString < $1.value.uuidString }
    }

    public func loops(for thread: AgentThreadID) -> [DistillLoopState] {
        snapshot[thread] ?? []
    }

    public func update(thread: AgentThreadID, loops: [DistillLoopState]) {
        if loops.isEmpty {
            snapshot.removeValue(forKey: thread)
        } else {
            snapshot[thread] = loops
        }
        save()
        let encoded = (try? JSONEncoder().encode(loops))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .array([])
        bus.publish(
            kind: .agentThreadLoopsUpdated,
            payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "loops": encoded,
            ])
        )
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.value.uuidString, $0.value) })
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DistillLoopStore save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> [AgentThreadID: [DistillLoopState]] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: [DistillLoopState]].self, from: data) else { return [:] }
        var result: [AgentThreadID: [DistillLoopState]] = [:]
        for (key, loops) in stored {
            if let uuid = UUID(uuidString: key) { result[AgentThreadID(uuid)] = loops }
        }
        return result
    }
}
