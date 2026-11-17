import Foundation

/// `client.perf.report {lines: [string]}` (welcome capability
/// `client.perf.report.v1`): a paired phone appends its own perf-milestone
/// JSONL lines to a bounded host log so a resume can be measured end to end.
/// Diagnostics only: it never reads or changes user state.
public enum ClientPerfReport {
    public static let method = "client.perf.report"
    public static let capability = "client.perf.report.v1"
    /// Bound on the UTF-8 bytes of one call's lines, newlines included.
    public static let maxCallBytes = 64 * 1024
    /// The active file rotates to `ios-perf.1.jsonl` before it would pass this.
    public static let maxFileBytes = 1024 * 1024

    /// `~/Library/Logs/RemoteCode/ios-perf.jsonl`. `HOME` wins over the account
    /// home so the isolated sandbox app writes into its own home.
    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Logs/RemoteCode", isDirectory: true)
            .appendingPathComponent("ios-perf.jsonl")
    }

    /// The JSONL bytes of a call: every line one JSON object on one line.
    /// Any invalid line or an oversize call rejects the whole call, so the
    /// file only ever holds complete records.
    static func payload(from params: [String: JSONValue]) throws -> (data: Data, count: Int) {
        guard case .array(let values) = params["lines"] ?? .null else { throw JSONRPCError.invalidParams }
        var data = Data()
        for value in values {
            guard let line = value.stringValue,
                  !line.contains(where: { $0 == "\n" || $0 == "\r" }),
                  let bytes = line.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else {
                throw JSONRPCError(code: -32602, message: "Each perf line must be one JSON object.")
            }
            data.append(bytes)
            data.append(0x0A)
            guard data.count <= maxCallBytes else {
                throw JSONRPCError(code: -32602, message: "A perf report is limited to 64 KB.")
            }
        }
        return (data, values.count)
    }
}

/// Appends perf lines off the main actor and keeps the active file under
/// `ClientPerfReport.maxFileBytes`, with one rotated predecessor.
public actor ClientPerfReportLog {
    public static let shared = ClientPerfReportLog(fileURL: ClientPerfReport.defaultFileURL())

    public nonisolated let fileURL: URL
    public nonisolated var rotatedFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("1.jsonl")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = ((try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + data.count > ClientPerfReport.maxFileBytes {
            try? manager.removeItem(at: rotatedFileURL)
            try manager.moveItem(at: fileURL, to: rotatedFileURL)
        }
        guard manager.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
