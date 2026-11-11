import Foundation
import CoreModel

/// Capacity UX honesty model (S12 / T-003).
///
/// Shows tier, envelope status, host vs provider-tree pressure, degradation
/// actions, unavailable accounting, and redacted diagnostic export affordance.
/// Text/VoiceOver/non-color status only — no modal interruption.

public enum CapacityEnvelopeStatus: String, Sendable, Equatable {
    case withinMeasuredEnvelope
    case beyondMeasuredEnvelope
    case unmeasured
    case accountingUnavailable
}

public struct CapacityUXStatus: Sendable, Equatable {
    public var hardwareTierName: String
    public var envelope: CapacityEnvelopeStatus
    public var hostPressure: PressureLevel
    public var providerTreePressure: PressureLevel
    public var degradationActions: [String]
    public var unavailableSections: [String]
    public var canExportDiagnostics: Bool

    /// Always derived from current fields so VoiceOver cannot announce stale text.
    public var accessibleSummary: String {
        Self.buildAccessibleSummary(
            tier: hardwareTierName,
            envelope: envelope,
            host: hostPressure,
            provider: providerTreePressure,
            actions: degradationActions,
            unavailable: unavailableSections
        )
    }

    public init(
        hardwareTierName: String,
        envelope: CapacityEnvelopeStatus,
        hostPressure: PressureLevel,
        providerTreePressure: PressureLevel,
        degradationActions: [String],
        unavailableSections: [String],
        canExportDiagnostics: Bool
    ) {
        self.hardwareTierName = hardwareTierName
        self.envelope = envelope
        self.hostPressure = hostPressure
        self.providerTreePressure = providerTreePressure
        self.degradationActions = degradationActions
        self.unavailableSections = unavailableSections
        self.canExportDiagnostics = canExportDiagnostics
    }

    public static func buildAccessibleSummary(
        tier: String,
        envelope: CapacityEnvelopeStatus,
        host: PressureLevel,
        provider: PressureLevel,
        actions: [String],
        unavailable: [String]
    ) -> String {
        var parts: [String] = []
        parts.append(L("Hardware tier %1$@", tier))
        switch envelope {
        case .withinMeasuredEnvelope:
            parts.append(L("within measured capacity envelope"))
        case .beyondMeasuredEnvelope:
            parts.append(L("beyond measured capacity envelope; responsiveness not guaranteed"))
        case .unmeasured:
            parts.append(L("envelope not yet physically measured"))
        case .accountingUnavailable:
            parts.append(L("memory accounting unavailable"))
        }
        parts.append(L("host pressure %1$@", host.rawValue))
        parts.append(L("provider tree pressure %1$@", provider.rawValue))
        if !actions.isEmpty {
            parts.append("actions: \(actions.joined(separator: ", "))")
        }
        if !unavailable.isEmpty {
            parts.append("unavailable: \(unavailable.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ") + "."
    }

    /// Scheduled occurrence behavior is never altered by pressure (S7/S12 cut).
    public static let pressureDefersScheduledOccurrences = false

    /// Explicit release is only for completed idle sessions.
    public static let userMayReleaseLiveProviderRSS = false

    /// Build status from live pressure governor + envelope measurement honesty.
    public static func from(
        hardwareTierName: String,
        hostPressure: PressureLevel,
        providerTreePressure: PressureLevel,
        envelopeMeasured: Bool,
        beyondEnvelope: Bool,
        accountingAvailable: Bool,
        degradationActions: [String],
        unavailableSections: [String] = []
    ) -> CapacityUXStatus {
        let envelope: CapacityEnvelopeStatus = {
            if !accountingAvailable { return .accountingUnavailable }
            if !envelopeMeasured { return .unmeasured }
            return beyondEnvelope ? .beyondMeasuredEnvelope : .withinMeasuredEnvelope
        }()
        return CapacityUXStatus(
            hardwareTierName: hardwareTierName,
            envelope: envelope,
            hostPressure: hostPressure,
            providerTreePressure: providerTreePressure,
            degradationActions: degradationActions,
            unavailableSections: unavailableSections,
            canExportDiagnostics: true
        )
    }
}

/// Process-wide capacity UX snapshot for Settings / diagnostics (S12).
/// Production code publishes here so status is not test-only.
public final class CapacityUXStatusStore: @unchecked Sendable {
    public static let shared = CapacityUXStatusStore()
    public static let didChangeNotification = Notification.Name("io.remotecode.capacityUX.didChange")

    private let lock = NSLock()
    private var _status: CapacityUXStatus = CapacityUXStatus.from(
        hardwareTierName: "unmeasured",
        hostPressure: .normal,
        providerTreePressure: .normal,
        envelopeMeasured: false,
        beyondEnvelope: false,
        accountingAvailable: true,
        degradationActions: []
    )
    private var _generation: UInt64 = 0

    public func current() -> CapacityUXStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    public func generation() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    public func publish(_ status: CapacityUXStatus) {
        lock.lock()
        _status = status
        _generation &+= 1
        let gen = _generation
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: CapacityUXStatusStore.didChangeNotification,
                object: nil,
                userInfo: ["generation": gen]
            )
        }
    }

    public func publishFromPressure(
        host: PressureLevel,
        providerTree: PressureLevel = .normal,
        actions: [String] = []
    ) {
        let next = CapacityUXStatus.from(
            hardwareTierName: current().hardwareTierName,
            hostPressure: host,
            providerTreePressure: providerTree,
            envelopeMeasured: false,
            beyondEnvelope: false,
            accountingAvailable: true,
            degradationActions: actions
        )
        publish(next)
    }
}
