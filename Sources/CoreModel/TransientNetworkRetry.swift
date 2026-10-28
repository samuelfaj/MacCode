import Foundation

/// Failed turns resume automatically unless the failure is known to repeat on
/// every attempt (auth, billing/quota caps, bad configuration, ownership,
/// session-shape errors with their own recovery). When in doubt, retry.
public enum TransientNetworkRetry {
    /// Marker the Distill/Grok ACP clients put on network-class failures.
    public static let marker = "[retryable:network]"
    /// Only the guest adapter may emit this: its lease serializes cleanup
    /// with the next run's host preparation. A Mac process exit is not enough.
    public static let guestProcessMarker = "[retryable:guest-process]"
    /// The provider stopped answering mid-turn; the adapter drops the hung
    /// process, so resuming the same session is safe.
    public static let timeoutMarker = "[retryable:timeout]"

    public static let prompt = """
    The previous turn was interrupted before it finished. Continue the original task from where you stopped; do not repeat work that already completed.
    """

    /// Lowercased fragments of failures that a plain resume cannot fix.
    static let permanentFailureMarkers = [
        // Auth: needs the user to sign in again.
        "[auth-required]", "failed to authenticate", "oauth session expired", "unauthorized",
        // Billing and hard usage caps.
        "payment required", "balance exhausted", "usage balance", "usage limit", "weekly limit",
        "purchase more credits",
        // Configuration the user must change.
        "not advertised", "unknown model id", "select an explicit", "auto routing is off",
        "operation unsupported", "upgrade required", "is outdated", "configuration error",
        // Ownership and environment.
        "belongs to another workspace", "vm unavailable", "share one vm",
        "already has an in-flight turn",
        // Session-shape failures recovered by a fresh session elsewhere.
        "[start-fresh:",
        // User or app intent.
        "cancelled", "cancellationerror"
    ]

    public static func isRetryableInterruption(_ errorMessage: String?) -> Bool {
        guard let errorMessage, !errorMessage.isEmpty else { return false }
        if errorMessage.hasPrefix(marker) || errorMessage.hasPrefix(guestProcessMarker)
            || errorMessage.hasPrefix(timeoutMarker) {
            return true
        }
        let normalized = errorMessage.lowercased()
        return !permanentFailureMarkers.contains(where: normalized.contains)
    }
}
