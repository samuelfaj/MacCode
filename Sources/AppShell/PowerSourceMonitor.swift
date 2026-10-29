import Foundation
import IOKit.ps

public enum ExternalPowerState: Equatable {
    case externalPower
    case battery
    case unknown
}

public protocol ExternalPowerMonitoring: AnyObject {
    var currentPowerState: ExternalPowerState { get }
    var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - PowerSourceProvider DI seam (QA :97)

/// Abstracts the IOKit power-source read so the AC/battery/unknown mapping
/// in `MacOSExternalPowerMonitor` is unit-testable without real IOKit hardware.
/// The closure returns an array of state strings (one per power source, in
/// iteration order). An empty array maps to `.unknown`.
/// Production code uses `iokitPowerSourceProvider`; tests inject a fixed array.
public typealias PowerSourceProvider = @Sendable () -> [String]

/// The live provider: reads power-source descriptions from IOKit and returns
/// the `kIOPSPowerSourceStateKey` value for each source in the list.
public let iokitPowerSourceProvider: PowerSourceProvider = {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return []
    }
    return sources.compactMap { source in
        (IOPSGetPowerSourceDescription(info, source)?
            .takeUnretainedValue() as NSDictionary?)?[kIOPSPowerSourceStateKey] as? String
    }
}

/// Maps an array of power-source state strings (as returned by a
/// `PowerSourceProvider`) to an `ExternalPowerState`.
/// Pure and `nonisolated` — no I/O, testable without IOKit.
public func mapPowerSourceStates(_ states: [String]) -> ExternalPowerState {
    for state in states {
        if state == kIOPSACPowerValue   { return .externalPower }
        if state == kIOPSBatteryPowerValue { return .battery }
    }
    return .unknown
}

public final class MacOSExternalPowerMonitor: ExternalPowerMonitoring {
    private var runLoopSource: CFRunLoopSource?
    private var started = false
    public var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?

    /// Injected power-source reader. Default = live IOKit. Tests inject a fixed closure.
    private let powerSourceProvider: PowerSourceProvider

    public convenience init() {
        self.init(powerSourceProvider: iokitPowerSourceProvider)
    }

    /// Designated init for test injection.
    public init(powerSourceProvider: @escaping PowerSourceProvider) {
        self.powerSourceProvider = powerSourceProvider
    }

    public var currentPowerState: ExternalPowerState {
        mapPowerSourceStates(powerSourceProvider())
    }

    public func start() {
        guard !started else { return }
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<MacOSExternalPowerMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            monitor.publishCurrentPowerState()
        }, Unmanaged.passUnretained(self).toOpaque()) else {
            return
        }
        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        started = true
    }

    public func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
        started = false
    }

    /// Runs in the main run loop's IOKit callout, already on the main thread.
    /// The handler may open a modal alert. Calling it from here keeps its
    /// nested event loop able to drain the main queue; a `Task { @MainActor }`
    /// hop would run it inside a main-queue job, and every main-actor job
    /// (all remote RPCs) would wait until the alert is dismissed.
    private func publishCurrentPowerState() {
        let state = currentPowerState
        MainActor.assumeIsolated {
            onPowerStateChanged?(state)
        }
    }

    deinit {
        stop()
    }
}
