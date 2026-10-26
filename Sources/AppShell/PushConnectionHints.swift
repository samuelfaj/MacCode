import Foundation

/// Connection + catch-up hints merged into every host -> iOS push `data`
/// (alert, silent catch-up, and outbox replay).
enum PushConnectionHints {
    /// Returns `data` plus `rc2_wm` / `rc2_boot_epoch`, never overwriting existing values.
    static func merge(
        into data: [String: String],
        watermark: String?,
        bootEpoch: String?
    ) -> [String: String] {
        var out = data
        let catchUp = SilentCatchUpV1(watermark: watermark, bootEpoch: bootEpoch).asPushData()
        for key in [SilentCatchUpV1.watermarkKey, SilentCatchUpV1.bootEpochKey] where out[key] == nil {
            if let value = catchUp[key] { out[key] = value }
        }
        return out
    }

    /// Bounded RemoteCode delta for alert and silent pushes. Mirrors the backend
    /// bounds (ids 64 chars, seq decimal digits) so the backend never drops a field.
    /// Preview is cut to 160 UTF-16 units without leaving a lone high surrogate.
    static func delta(
        threadId: String?,
        workspaceId: String?,
        state: String?,
        kind: String?,
        preview: String?,
        seq: String?
    ) -> [String: String] {
        var out: [String: String] = [:]
        for (key, raw) in [("thread_id", threadId), ("workspace_id", workspaceId), ("state", state), ("kind", kind)] {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, value.count <= 64 { out[key] = value }
        }
        let seqValue = seq?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !seqValue.isEmpty, seqValue.count <= 20, seqValue.allSatisfy(\.isASCII), seqValue.allSatisfy(\.isNumber) {
            out["seq"] = seqValue
        }
        let units = Array((preview ?? "").utf16.prefix(160))
        var cut = String(decoding: units, as: UTF16.self)
        if let last = units.last, (0xD800...0xDBFF).contains(last) {
            cut = String(decoding: units.dropLast(), as: UTF16.self)
        }
        if !cut.isEmpty { out["preview"] = cut }
        return out
    }
}
