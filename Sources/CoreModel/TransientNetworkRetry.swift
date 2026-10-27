import Foundation

/// Provider failures that are worth resuming automatically: the network or the
/// response stream dropped mid-turn, or an owned guest process was killed.
/// Auth, rate-limit, payment and request errors still stop the run.
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

    public static func isRetryableInterruption(_ errorMessage: String?) -> Bool {
        guard let errorMessage else { return false }
        return errorMessage.hasPrefix(marker) || errorMessage.hasPrefix(guestProcessMarker)
            || errorMessage.hasPrefix(timeoutMarker)
    }
}
