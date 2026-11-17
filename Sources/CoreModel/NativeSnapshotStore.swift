import ApplicationServices
import CryptoKit
import Foundation

/// What a caller was shown when it read a window: the AX element behind each `ax_<n>`, and the
/// size of the screenshot it was given. An action presents what it read; the element and the
/// scale are found here instead of being recomputed from a window that has moved on since.
final class NativeSnapshotStore: @unchecked Sendable {
    struct Identity: Equatable {
        var role: String?
        var title: String?
        var description: String?
        var identifier: String?
    }

    enum Resolution {
        case found(AXUIElement)
        /// The element is gone, or is no longer the control the caller read.
        case changed
        /// Nothing is held for that observation; the caller decides how strict to be.
        case unknown
    }

    static let shared = NativeSnapshotStore()
    static let snapshotsPerWindow = 8
    static let trackedWindows = 16

    /// The observation an element id belongs to, for the length of one tool call.
    @TaskLocal static var actionToken: String?

    private struct Snapshot {
        let digest: String
        let elements: [AXUIElement]
        let identities: [Identity]
    }

    private struct Window {
        var snapshots: [Snapshot] = []
        var tokens: [String: String] = [:]
        var delivered: String?
        var screenshot: (image: [Int], window: CGSize)?
    }

    private let lock = NSLock()
    private var windows: [ComputerUseNativeHostTarget: Window] = [:]
    private var recency: [ComputerUseNativeHostTarget] = []

    static func digest(_ tree: String) -> String {
        SHA256.hash(data: Data(tree.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ target: ComputerUseNativeHostTarget) {
        recency.removeAll { $0 == target }
        recency.append(target)
        while recency.count > Self.trackedWindows { windows.removeValue(forKey: recency.removeFirst()) }
    }

    func publish(target: ComputerUseNativeHostTarget, tree: String, elements: [AXUIElement], identities: [Identity]) {
        let digest = Self.digest(tree)
        lock.lock()
        defer { lock.unlock() }
        touch(target)
        var window = windows[target] ?? Window()
        window.snapshots.removeAll { $0.digest == digest }
        window.snapshots.append(Snapshot(digest: digest, elements: elements, identities: identities))
        if window.snapshots.count > Self.snapshotsPerWindow { window.snapshots.removeFirst(window.snapshots.count - Self.snapshotsPerWindow) }
        let held = Set(window.snapshots.map(\.digest))
        window.tokens = window.tokens.filter { held.contains($0.value) }
        windows[target] = window
    }

    /// Ties the state token a caller receives to the tree it describes.
    func bind(token: String, tree: String, target: ComputerUseNativeHostTarget) {
        let digest = Self.digest(tree)
        lock.lock()
        defer { lock.unlock() }
        guard windows[target]?.snapshots.contains(where: { $0.digest == digest }) == true else { return }
        windows[target]?.tokens[token] = digest
    }

    /// The tree a caller last received; an id with no token refers to it.
    func deliver(token: String, target: ComputerUseNativeHostTarget) {
        lock.lock()
        defer { lock.unlock() }
        if let digest = windows[target]?.tokens[token] { windows[target]?.delivered = digest }
    }

    func resolve(target: ComputerUseNativeHostTarget, index: Int, token: String?,
                 identity: (AXUIElement) -> Identity?) -> Resolution {
        lock.lock()
        let window = windows[target]
        lock.unlock()
        guard let window, let digest = token.map({ window.tokens[$0] }) ?? window.delivered,
              let snapshot = window.snapshots.first(where: { $0.digest == digest }) else { return .unknown }
        guard snapshot.elements.indices.contains(index) else { return .changed }
        return identity(snapshot.elements[index]) == snapshot.identities[index] ? .found(snapshot.elements[index]) : .changed
    }

    func recordScreenshot(target: ComputerUseNativeHostTarget, imageSize: [Int], windowSize: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        touch(target)
        var window = windows[target] ?? Window()
        window.screenshot = (imageSize, windowSize)
        windows[target] = window
    }

    /// Image pixels per window point of the last screenshot given for this window, while the
    /// window still has the size it had then.
    func screenshotPixelsPerPoint(target: ComputerUseNativeHostTarget, windowSize: CGSize) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let shot = windows[target]?.screenshot, shot.image.count == 2, shot.window.width > 0,
              abs(shot.window.width - windowSize.width) < 1, abs(shot.window.height - windowSize.height) < 1 else { return nil }
        return Double(shot.image[0]) / Double(shot.window.width)
    }

    func reset() {
        lock.lock()
        windows.removeAll()
        recency.removeAll()
        lock.unlock()
    }
}
