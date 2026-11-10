import AppKit
import CoreModel
import DesignSystemKit
import ImageIO
import SwiftUI

public enum AgentChatThreadStatusMark: Equatable {
    case hidden
    case running
    case unread
    case symbol(name: String, color: Color, size: CGFloat)
}

/// One stop affordance for Agent App and dest thread rows.
public enum AgentChatThreadRowStopChrome {
    public static let symbolName = "stop.circle"
    public static let accessibilityLabel = "Stop thread"
    public static let help = "Stop this thread"

    public static func isVisible(
        status: AgentChatThreadStatusMark,
        hasStopHandler: Bool
    ) -> Bool {
        status == .running && hasStopHandler
    }
}

public struct AgentChatThreadRow<Leading: View, Trailing: View>: View, Equatable {
    public let title: String
    public let subtitle: String
    public let unread: Bool
    public let selected: Bool
    public let status: AgentChatThreadStatusMark
    public let identifier: String
    public let onSelect: () -> Void
    public var unreadIdentifier: String?
    public var runningIdentifier: String?
    public var stopIdentifier: String?
    public var onStop: (() -> Void)?
    public var leading: Leading
    public var trailing: Trailing

    public init(
        title: String,
        subtitle: String,
        unread: Bool,
        selected: Bool,
        status: AgentChatThreadStatusMark,
        identifier: String,
        unreadIdentifier: String? = nil,
        runningIdentifier: String? = nil,
        stopIdentifier: String? = nil,
        onSelect: @escaping () -> Void,
        onStop: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.unread = unread
        self.selected = selected
        self.status = status
        self.identifier = identifier
        self.unreadIdentifier = unreadIdentifier
        self.runningIdentifier = runningIdentifier
        self.stopIdentifier = stopIdentifier
        self.onSelect = onSelect
        self.onStop = onStop
        self.leading = leading()
        self.trailing = trailing()
    }

    public static func == (lhs: AgentChatThreadRow<Leading, Trailing>, rhs: AgentChatThreadRow<Leading, Trailing>) -> Bool {
        lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.unread == rhs.unread
            && lhs.selected == rhs.selected
            && lhs.status == rhs.status
            && lhs.identifier == rhs.identifier
            && (lhs.onStop == nil) == (rhs.onStop == nil)
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Space.md) {
                statusMark
                    // DSBusySpinner's box, so the title does not shift when a run starts.
                    .frame(width: 16, height: 16)
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.bodyDense.weight(unread ? .semibold : .regular))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if unread {
                    Circle()
                        .fill(DS.Palette.accent)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unread activity")
                        .accessibilityIdentifier(unreadIdentifier ?? "\(identifier).unread")
                }
                trailing
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.selection : Color.clear)
            .dsHoverFill(enabled: !selected)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { stopControl }
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var stopControl: some View {
        if AgentChatThreadRowStopChrome.isVisible(status: status, hasStopHandler: onStop != nil),
           let onStop {
            Button(action: onStop) {
                Image(systemName: AgentChatThreadRowStopChrome.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.danger.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The 22pt hit box is wider than the glyph; the smaller inset
            // keeps the glyph where it was.
            .padding(.trailing, DS.Space.xs)
            .accessibilityLabel(AgentChatThreadRowStopChrome.accessibilityLabel)
            .accessibilityIdentifier(stopIdentifier ?? "\(identifier).stop")
            .help(AgentChatThreadRowStopChrome.help)
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        switch status {
        case .hidden:
            Color.clear.frame(width: 8, height: 8)
        case .running:
            // Same spinner as the Bots roster and the workspace rows.
            DSBusySpinner(
                label: "Running",
                identifier: runningIdentifier ?? "\(identifier).running"
            )
        case .unread:
            Circle()
                .fill(DS.Palette.accent)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Unread")
        case .symbol(let name, let color, let size):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 8, height: 8)
        }
    }
}

/// Provider monogram chip at the leading edge of a thread row. Agent
/// App and Desk mount the same chip — the rails must not fork it.
public struct AgentThreadProviderMonogram: View {
    public let provider: AgentProvider

    public init(provider: AgentProvider) {
        self.provider = provider
    }

    public var body: some View {
        Text(AgentThreadRailRowCopy.monogram(for: provider))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(DS.Palette.textSecondary)
            .frame(width: 16, height: 16)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }
}

public extension AgentChatThreadRow where Leading == EmptyView, Trailing == EmptyView {
    init(
        title: String,
        subtitle: String,
        unread: Bool,
        selected: Bool,
        status: AgentChatThreadStatusMark,
        identifier: String,
        unreadIdentifier: String? = nil,
        runningIdentifier: String? = nil,
        stopIdentifier: String? = nil,
        onSelect: @escaping () -> Void,
        onStop: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            unread: unread,
            selected: selected,
            status: status,
            identifier: identifier,
            unreadIdentifier: unreadIdentifier,
            runningIdentifier: runningIdentifier,
            stopIdentifier: stopIdentifier,
            onSelect: onSelect,
            onStop: onStop,
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

public struct AgentQueuedRow<Trailing: View>: View {
    public let text: String
    public let identifier: String
    public var leading: AnyView? = nil
    public var detail: AnyView? = nil
    public var trailing: Trailing

    public init(
        text: String,
        identifier: String,
        leading: AnyView? = nil,
        detail: AnyView? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.text = text
        self.identifier = identifier
        self.leading = leading
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            if let leading {
                leading
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                // Empty text lets a caller replace the preview (an inline editor in `detail`).
                if !text.isEmpty {
                    Text(text)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(3)
                }
                if let detail {
                    detail
                }
            }
            Spacer(minLength: DS.Space.sm)
            trailing
        }
        .accessibilityIdentifier(identifier)
    }
}

struct AgentAttachmentThumbnailKey: Hashable, Sendable {
    let path: String
    let modificationTimeNanoseconds: Int64
    let sizeBytes: Int64
    let maxPixel: Int

    init(
        path: String,
        modificationTimeNanoseconds: Int64,
        sizeBytes: Int64,
        maxPixel: Int = 64
    ) {
        self.path = path
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.sizeBytes = sizeBytes
        self.maxPixel = max(1, maxPixel)
    }
}

struct AgentAttachmentDecodedThumbnail {
    let image: NSImage
    let costBytes: Int
}

struct AgentAttachmentThumbnailResult {
    let key: AgentAttachmentThumbnailKey
    let image: NSImage
}

/// Strict decoded-pixel-cost LRU. Unlike NSCache, both limits are hard invariants;
/// the entry cap also bounds object/key overhead that pixel cost does not include.
struct AgentAttachmentThumbnailMemoryCache {
    private struct Entry {
        let value: AgentAttachmentDecodedThumbnail
        var lastAccess: UInt64
    }

    let costLimitBytes: Int
    let countLimit: Int
    private var entries: [AgentAttachmentThumbnailKey: Entry] = [:]
    private var accessClock: UInt64 = 0
    private(set) var totalCostBytes = 0

    init(costLimitBytes: Int, countLimit: Int) {
        self.costLimitBytes = max(0, costLimitBytes)
        self.countLimit = max(0, countLimit)
    }

    var count: Int { entries.count }

    mutating func value(for key: AgentAttachmentThumbnailKey) -> AgentAttachmentDecodedThumbnail? {
        guard var entry = entries[key] else { return nil }
        accessClock &+= 1
        entry.lastAccess = accessClock
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: AgentAttachmentDecodedThumbnail, for key: AgentAttachmentThumbnailKey) {
        let cost = max(1, value.costBytes)
        guard cost <= costLimitBytes, countLimit > 0 else { return }

        // Only the newest signature for a path/presentation size is useful. Drop
        // replaced payloads eagerly while allowing chip and transcript resolutions
        // of the same current file to coexist inside the shared hard budget.
        let obsoleteKeys = entries.keys.filter {
            $0.path == key.path && $0.maxPixel == key.maxPixel && $0 != key
        }
        for obsoleteKey in obsoleteKeys {
            remove(obsoleteKey)
        }
        remove(key)
        while totalCostBytes + cost > costLimitBytes || entries.count >= countLimit {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else {
                break
            }
            remove(oldest)
        }

        accessClock &+= 1
        entries[key] = Entry(value: value, lastAccess: accessClock)
        totalCostBytes += cost
    }

    private mutating func remove(_ key: AgentAttachmentThumbnailKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCostBytes -= max(1, removed.value.costBytes)
    }
}

actor AgentAttachmentThumbnailLoader {
    struct CacheSnapshot: Sendable, Equatable {
        let costBytes: Int
        let entryCount: Int
        let activeDecodeCount: Int
        let waitingDecodeCount: Int
        let inFlightDecodeCount: Int
        let inFlightConsumerCount: Int
    }

    private struct DecodeWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct InFlightDecode {
        let id: UUID
        let task: Task<AgentAttachmentDecodedThumbnail?, Never>
        var consumers: Set<UUID>
    }

    typealias Decoder = @Sendable (String, Int) -> AgentAttachmentDecodedThumbnail?
    typealias RetrySleeper = @Sendable (UInt64) async -> Bool

    private enum LoadAttempt {
        case loaded(AgentAttachmentThumbnailResult)
        case unavailable
        case saturated
    }

    static let shared = AgentAttachmentThumbnailLoader()
    static let defaultCostLimitBytes = 2 * 1_024 * 1_024
    static let defaultCountLimit = 128
    static let defaultMaxPixel = 64
    static let defaultMaxConcurrentDecodes = 2
    static let defaultMaxWaitingDecodes = 8
    /// AppKit SVG rasterization (`NSImage(contentsOf:)`) is skipped above this
    /// on-disk size. ImageIO remains the unbounded-safe path for raster files.
    static let maxAppKitSVGFallbackBytes: Int64 = 2 * 1_024 * 1_024
    private static let transcriptSaturationRetryNanoseconds: [UInt64] = [
        25_000_000,
        50_000_000,
        100_000_000,
        200_000_000,
        250_000_000,
        250_000_000,
        250_000_000,
        250_000_000,
    ]

    private var cache: AgentAttachmentThumbnailMemoryCache
    private let maxPixel: Int
    private let maxConcurrentDecodes: Int
    private let maxWaitingDecodes: Int
    private let decoder: Decoder
    private let retrySleeper: RetrySleeper
    private var activeDecodeCount = 0
    private var decodeWaiters: [DecodeWaiter] = []
    private var inFlightDecodes: [AgentAttachmentThumbnailKey: InFlightDecode] = [:]

    init(
        costLimitBytes: Int = AgentAttachmentThumbnailLoader.defaultCostLimitBytes,
        countLimit: Int = AgentAttachmentThumbnailLoader.defaultCountLimit,
        maxPixel: Int = AgentAttachmentThumbnailLoader.defaultMaxPixel,
        maxConcurrentDecodes: Int = AgentAttachmentThumbnailLoader.defaultMaxConcurrentDecodes,
        maxWaitingDecodes: Int = AgentAttachmentThumbnailLoader.defaultMaxWaitingDecodes,
        decoder: Decoder? = nil,
        retrySleeper: RetrySleeper? = nil
    ) {
        cache = AgentAttachmentThumbnailMemoryCache(
            costLimitBytes: costLimitBytes,
            countLimit: countLimit
        )
        self.maxPixel = max(1, maxPixel)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.maxWaitingDecodes = max(0, maxWaitingDecodes)
        self.decoder = decoder ?? { path, maxPixel in
            AgentAttachmentThumbnailLoader.decodeImage(path: path, maxPixel: maxPixel)
        }
        self.retrySleeper = retrySleeper ?? { nanoseconds in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                return true
            } catch {
                return false
            }
        }
    }

    func thumbnail(
        forPath path: String,
        maxPixel requestedMaxPixel: Int? = nil
    ) async -> AgentAttachmentThumbnailResult? {
        switch await loadAttempt(forPath: path, maxPixel: requestedMaxPixel) {
        case .loaded(let result):
            return result
        case .unavailable, .saturated:
            return nil
        }
    }

    private func loadAttempt(
        forPath path: String,
        maxPixel requestedMaxPixel: Int? = nil
    ) async -> LoadAttempt {
        // Admission covers stat + decode, not just the expensive decoder. This
        // keeps detached metadata reads and actor continuations bounded when a
        // caller presents a large attachment batch. A saturated decorative
        // thumbnail remains the existing photo placeholder.
        // A replacement racing a detached decode gets one retry with its new signature.
        let requestedMaxPixel = max(1, requestedMaxPixel ?? maxPixel)
        for _ in 0..<2 {
            guard await acquireDecodePermit() else {
                return Task.isCancelled ? .unavailable : .saturated
            }
            guard !Task.isCancelled,
                  let key = await readFileKey(forPath: path, maxPixel: requestedMaxPixel) else {
                releaseDecodePermit()
                return .unavailable
            }
            guard !Task.isCancelled else {
                releaseDecodePermit()
                return .unavailable
            }
            if let cached = cache.value(for: key) {
                releaseDecodePermit()
                return .loaded(AgentAttachmentThumbnailResult(key: key, image: cached.image))
            }

            // This call consumes the permit: a coalesced/cache-hit caller releases
            // it immediately, while a new physical decode releases it on completion.
            let decoded = await decodedThumbnailConsumingPermit(for: key)
            guard !Task.isCancelled, let decoded else { return .unavailable }
            guard let currentKey = await readFileKey(
                forPath: path,
                maxPixel: requestedMaxPixel
            ), currentKey == key else {
                continue
            }
            cache.insert(decoded, for: key)
            return .loaded(AgentAttachmentThumbnailResult(key: key, image: decoded.image))
        }
        return .unavailable
    }

    /// Transcript cards share the same cache/admission authority as composer
    /// chips. 320 pt featured cards need at most 640 px on Retina displays;
    /// grouped 112 pt strips retain their prior 280 px decode budget.
    func transcriptThumbnail(
        forPath path: String,
        featured: Bool
    ) async -> AgentAttachmentThumbnailResult? {
        let maxPixel = featured ? 640 : 280
        for retryIndex in 0...Self.transcriptSaturationRetryNanoseconds.count {
            switch await loadAttempt(forPath: path, maxPixel: maxPixel) {
            case .loaded(let result):
                return result
            case .unavailable:
                return nil
            case .saturated:
                guard retryIndex < Self.transcriptSaturationRetryNanoseconds.count,
                      !Task.isCancelled,
                      await retrySleeper(Self.transcriptSaturationRetryNanoseconds[retryIndex]) else {
                    return nil
                }
            }
        }
        return nil
    }

    func cacheSnapshot() -> CacheSnapshot {
        CacheSnapshot(
            costBytes: cache.totalCostBytes,
            entryCount: cache.count,
            activeDecodeCount: activeDecodeCount,
            waitingDecodeCount: decodeWaiters.count,
            inFlightDecodeCount: inFlightDecodes.count,
            inFlightConsumerCount: inFlightDecodes.values.reduce(0) { partial, decode in
                partial + decode.consumers.count
            }
        )
    }

    nonisolated static func fileKey(
        forPath path: String,
        maxPixel: Int = AgentAttachmentThumbnailLoader.defaultMaxPixel
    ) -> AgentAttachmentThumbnailKey? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        return AgentAttachmentThumbnailKey(
            path: path,
            modificationTimeNanoseconds: Int64((modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()),
            sizeBytes: size.int64Value,
            maxPixel: maxPixel
        )
    }

    nonisolated static func decodeImage(
        path: String,
        maxPixel: Int
    ) -> AgentAttachmentDecodedThumbnail? {
        let url = URL(fileURLWithPath: path)
        let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let source,
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return decodedThumbnail(from: cgImage)
        }

        // AppKit accepts a few formats (notably SVG) that ImageIO cannot thumbnail.
        // Rasterize those once on this detached decoder task so the old visible result
        // is preserved without retaining an unbounded source image. Skip the
        // NSImage(contentsOf:) path above 2 MiB — SVG XML can expand far beyond
        // the on-disk size once AppKit parses it.
        guard allowsAppKitImageFallback(path: path),
              let sourceImage = NSImage(contentsOf: url),
              sourceImage.size.width.isFinite,
              sourceImage.size.height.isFinite,
              sourceImage.size.width > 0,
              sourceImage.size.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixel) / max(sourceImage.size.width, sourceImage.size.height))
        let width = min(maxPixel, max(1, Int((sourceImage.size.width * scale).rounded())))
        let height = min(maxPixel, max(1, Int((sourceImage.size.height * scale).rounded())))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        sourceImage.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return decodedThumbnail(from: cgImage)
    }

    nonisolated static func allowsAppKitImageFallback(
        fileSizeBytes: Int64
    ) -> Bool {
        fileSizeBytes > 0 && fileSizeBytes <= maxAppKitSVGFallbackBytes
    }

    nonisolated static func allowsAppKitImageFallback(path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return allowsAppKitImageFallback(fileSizeBytes: size.int64Value)
    }

    nonisolated private static func decodedThumbnail(
        from cgImage: CGImage
    ) -> AgentAttachmentDecodedThumbnail {
        return AgentAttachmentDecodedThumbnail(
            image: NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            ),
            costBytes: max(1, cgImage.bytesPerRow * cgImage.height)
        )
    }

    private func readFileKey(
        forPath path: String,
        maxPixel: Int
    ) async -> AgentAttachmentThumbnailKey? {
        let task = Task.detached(priority: .utility) { () -> AgentAttachmentThumbnailKey? in
            guard !Task.isCancelled else { return nil }
            return Self.fileKey(forPath: path, maxPixel: maxPixel)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Called only after admission. Exactly one release occurs on every path:
    /// duplicate callers give their provisional permit back before awaiting,
    /// while the task that performs the physical decode owns it until it stops.
    private func decodedThumbnailConsumingPermit(
        for key: AgentAttachmentThumbnailKey
    ) async -> AgentAttachmentDecodedThumbnail? {
        guard !Task.isCancelled else {
            releaseDecodePermit()
            return nil
        }
        if let cached = cache.value(for: key) {
            releaseDecodePermit()
            return cached
        }

        if let existing = inFlightDecodes[key] {
            let consumerID = UUID()
            var registered = existing
            registered.consumers.insert(consumerID)
            inFlightDecodes[key] = registered
            releaseDecodePermit()
            return await awaitInFlightDecode(
                key: key,
                decodeID: existing.id,
                consumerID: consumerID,
                task: existing.task
            )
        }

        let decoder = self.decoder
        let maxPixel = key.maxPixel
        let id = UUID()
        let consumerID = UUID()
        let task = Task.detached(priority: .utility) { () -> AgentAttachmentDecodedThumbnail? in
            let decoded = Task.isCancelled ? nil : decoder(key.path, maxPixel)
            await self.releaseDecodePermit()
            return decoded
        }
        inFlightDecodes[key] = InFlightDecode(
            id: id,
            task: task,
            consumers: [consumerID]
        )
        return await awaitInFlightDecode(
            key: key,
            decodeID: id,
            consumerID: consumerID,
            task: task
        )
    }

    private func awaitInFlightDecode(
        key: AgentAttachmentThumbnailKey,
        decodeID: UUID,
        consumerID: UUID,
        task: Task<AgentAttachmentDecodedThumbnail?, Never>
    ) async -> AgentAttachmentDecodedThumbnail? {
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.cancelInFlightConsumer(
                    key: key,
                    decodeID: decodeID,
                    consumerID: consumerID
                )
            }
        }
        finishInFlightConsumer(
            key: key,
            decodeID: decodeID,
            consumerID: consumerID
        )
        return Task.isCancelled ? nil : decoded
    }

    private func cancelInFlightConsumer(
        key: AgentAttachmentThumbnailKey,
        decodeID: UUID,
        consumerID: UUID
    ) {
        guard var inFlight = inFlightDecodes[key], inFlight.id == decodeID,
              inFlight.consumers.remove(consumerID) != nil else { return }
        if inFlight.consumers.isEmpty {
            inFlight.task.cancel()
            inFlightDecodes.removeValue(forKey: key)
        } else {
            inFlightDecodes[key] = inFlight
        }
    }

    private func finishInFlightConsumer(
        key: AgentAttachmentThumbnailKey,
        decodeID: UUID,
        consumerID: UUID
    ) {
        guard var inFlight = inFlightDecodes[key], inFlight.id == decodeID,
              inFlight.consumers.remove(consumerID) != nil else { return }
        if inFlight.consumers.isEmpty {
            inFlightDecodes.removeValue(forKey: key)
        } else {
            inFlightDecodes[key] = inFlight
        }
    }

    private func acquireDecodePermit() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeDecodeCount < maxConcurrentDecodes {
            activeDecodeCount += 1
            return true
        }
        guard decodeWaiters.count < maxWaitingDecodes else { return false }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    decodeWaiters.append(DecodeWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelDecodeWaiter(id: id) }
        }
    }

    private func cancelDecodeWaiter(id: UUID) {
        guard let index = decodeWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = decodeWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseDecodePermit() {
        if decodeWaiters.isEmpty {
            activeDecodeCount = max(0, activeDecodeCount - 1)
        } else {
            let waiter = decodeWaiters.removeFirst()
            waiter.continuation.resume(returning: true)
        }
    }
}

private struct AgentChatAttachmentThumbnail: View {
    let path: String
    @State private var loaded: AgentAttachmentThumbnailResult?

    var body: some View {
        Group {
            if let loaded, loaded.key.path == path {
                Image(nsImage: loaded.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 9))
            }
        }
        .task(id: path) {
            loaded = nil
            let requestedPath = path
            let result = await AgentAttachmentThumbnailLoader.shared.thumbnail(forPath: requestedPath)
            guard !Task.isCancelled, result?.key.path == requestedPath else { return }
            loaded = result
        }
    }
}

public struct AgentChatAttachmentChips: View {
    public let attachments: [AgentAttachment]
    public let onRemove: (AgentAttachment) -> Void
    public var chipIdentifierPrefix: String = "bots.desk.attachment."
    public var stripIdentifier: String = "bots.desk.attachments"

    public init(
        attachments: [AgentAttachment],
        onRemove: @escaping (AgentAttachment) -> Void,
        chipIdentifierPrefix: String = "bots.desk.attachment.",
        stripIdentifier: String = "bots.desk.attachments"
    ) {
        self.attachments = attachments
        self.onRemove = onRemove
        self.chipIdentifierPrefix = chipIdentifierPrefix
        self.stripIdentifier = stripIdentifier
    }

    /// Stable SwiftUI identity for composer chips.
    /// WHY: `id: \.self` remounts the thumbnail `.task` when sizeBytes/sha256 fill in.
    static func chipIdentity(_ attachment: AgentAttachment) -> String {
        attachment.path
    }

    /// Path is the file; metadata-only changes must not remount the chip.
    static func wouldRemountChip(from old: AgentAttachment, to new: AgentAttachment) -> Bool {
        chipIdentity(old) != chipIdentity(new)
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: DS.Space.sm) {
                ForEach(attachments, id: \.path) { attachment in
                    HStack(spacing: DS.Space.xs) {
                        if AgentChatTranscriptChrome.isImagePath(attachment.path) {
                            AgentChatAttachmentThumbnail(path: attachment.path)
                        } else {
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                        }
                        Text(attachment.displayName)
                            .font(DS.Font.caption2).lineLimit(1)
                        Button { onRemove(attachment) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }
                    .foregroundColor(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 3)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    .accessibilityIdentifier("\(chipIdentifierPrefix)\(attachment.displayName)")
                }
            }
        }
        .accessibilityIdentifier(stripIdentifier)
    }
}

public struct AgentChatWorkingPill: View {
    public let label: String
    public var identifier: String = "agent.workingPhase"
    public var tone: DSPill.Tone = .accent
    public var help: String? = nil
    public var accessibilityLabelText: String? = nil
    public var padded: Bool = true

    public init(
        label: String,
        identifier: String = "agent.workingPhase",
        tone: DSPill.Tone = .accent,
        help: String? = nil,
        accessibilityLabelText: String? = nil,
        padded: Bool = true
    ) {
        self.label = label
        self.identifier = identifier
        self.tone = tone
        self.help = help
        self.accessibilityLabelText = accessibilityLabelText
        self.padded = padded
    }

    public var body: some View {
        let pill = DSPill(label, tone: tone)
            .help(help ?? label)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(accessibilityLabelText ?? label)
        if padded {
            HStack {
                pill
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
        } else {
            pill
        }
    }
}

/// Reduce Motion rule for chat transitions (pure, testable seam): the fade
/// stays, the slide or the scale goes.
public enum AgentChatMotion {
    public enum TransitionKind: Equatable {
        case fade
        /// Disclosure content entering from the top.
        case fadeAndMove
        /// The scroll-to-latest button growing in from 0.94.
        case fadeAndScale
    }

    public static func transitionKind(_ full: TransitionKind, reduceMotion: Bool) -> TransitionKind {
        reduceMotion ? .fade : full
    }

    public static func transition(_ full: TransitionKind, reduceMotion: Bool) -> AnyTransition {
        switch transitionKind(full, reduceMotion: reduceMotion) {
        case .fade:
            return .opacity
        case .fadeAndMove:
            return .opacity.combined(with: .move(edge: .top))
        case .fadeAndScale:
            return .opacity.combined(with: .scale(scale: 0.94))
        }
    }
}

/// Glyph and timing shared by every chat copy control.
public enum AgentChatCopyChrome {
    /// How long the check stays after a copy.
    public static let acknowledgementSeconds: TimeInterval = 1.5

    public static func symbolName(copied: Bool) -> String {
        copied ? "checkmark" : "doc.on.doc"
    }
}

/// The check's lifetime (pure, testable seam): a copy shows it, and only the
/// latest copy's timer may clear it.
public struct AgentChatCopyAcknowledgement: Equatable {
    public private(set) var copied = false
    private var generation = 0

    public init() {}

    /// Shows the check. Returns the generation to hand back to `expire`.
    public mutating func copy() -> Int {
        generation &+= 1
        copied = true
        return generation
    }

    /// Latest copy wins: an earlier timer must not clear a newer check.
    public mutating func expire(_ generation: Int) {
        guard generation == self.generation else { return }
        copied = false
    }
}

/// One copy control for the chat. It copies, then hands `copied == true` to
/// its label for `AgentChatCopyChrome.acknowledgementSeconds`, so the click
/// is answered where it happened. Each mount draws its own label.
public struct AgentChatCopyButton<Label: View>: View {
    private let text: String
    private let label: (Bool) -> Label
    @State private var acknowledgement = AgentChatCopyAcknowledgement()

    public init(text: String, @ViewBuilder label: @escaping (_ copied: Bool) -> Label) {
        self.text = text
        self.label = label
    }

    public var body: some View {
        Button {
            // Only a copy that reached the pasteboard gets the check.
            guard AgentChatTranscriptChrome.copyToPasteboard(text) else { return }
            let generation = acknowledgement.copy()
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentChatCopyChrome.acknowledgementSeconds) {
                acknowledgement.expire(generation)
            }
        } label: {
            label(acknowledgement.copied)
        }
        .buttonStyle(.plain)
        .accessibilityValue(acknowledgement.copied ? "Copied" : "")
    }
}

/// The word "Copy" that becomes the check in the same footprint, so the
/// message beside it does not rewrap. One label for the chat's strips.
public struct AgentChatCopyWordLabel: View {
    private let copied: Bool

    public init(copied: Bool) {
        self.copied = copied
    }

    public var body: some View {
        Text(L("Copy"))
            .opacity(copied ? 0 : 1)
            .overlay {
                if copied {
                    Image(systemName: AgentChatCopyChrome.symbolName(copied: true))
                }
            }
    }
}

/// Shared non-modal error strip. Agent App and the Bots roots mount this one
/// row so an error stays on screen with its recovery, without a blocking
/// alert and without reading as empty content.
public struct AgentChatErrorStrip: View {
    public let message: String
    public let identifier: String
    public var offersCopy: Bool
    /// Changes on every write of the owner's error slot, so the same message
    /// set again is spoken again. Nil: only a changed message is.
    public var announcementToken: Int?
    public var onRetry: (() -> Void)?
    /// Nil: no dismiss control. An error whose only recovery is Retry must
    /// not be hidden with nothing left on screen to recover from.
    public var onDismiss: (() -> Void)?

    public init(
        message: String,
        identifier: String,
        offersCopy: Bool = true,
        announcementToken: Int? = nil,
        onRetry: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.message = message
        self.identifier = identifier
        self.offersCopy = offersCopy
        self.announcementToken = announcementToken
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
                .frame(width: 14, height: 14, alignment: .center)
                .accessibilityHidden(true)
            AgentSelectablePlainText(
                text: message,
                fontSize: 11,
                textColor: DS.NS.text
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            if offersCopy {
                AgentChatCopyButton(text: message) { AgentChatCopyWordLabel(copied: $0) }
                .font(DS.Font.caption)
                .accessibilityLabel("Copy")
                .accessibilityIdentifier("\(identifier).copy")
            }
            if let onRetry {
                Button(L("Retry"), action: onRetry)
                    .buttonStyle(.plain)
                    .font(DS.Font.caption)
                    .accessibilityIdentifier("\(identifier).retry")
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Dismiss error")
                .accessibilityIdentifier("\(identifier).dismiss")
                .help("Dismiss error")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.danger.opacity(0.09))
        // Opaque base: a root may mount the strip over content.
        .background(DS.Palette.bg)
        // `.contain`, not `.combine`: Retry and Dismiss stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .onAppear { announce() }
        // One key, so a write that changes both message and token is spoken once.
        .onChange(of: "\(announcementToken ?? 0):\(message)") { _ in announce() }
    }

    /// The alert this strip replaces was spoken by VoiceOver; a silent row
    /// would hide the error from anyone not looking at it.
    private func announce() {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: (app.mainWindow as NSResponder?) ?? app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

public struct AgentChatPeerActivityRow: View {
    public let snapshot: BotPeerActivitySnapshot
    public let startedAt: Date
    /// The waiting bot's avatar. Falls back to initials when the bot has no
    /// Blobatar/symbol so the row always shows who is being waited on.
    public var avatarSymbol: String?

    public init(
        snapshot: BotPeerActivitySnapshot,
        startedAt: Date,
        avatarSymbol: String? = nil
    ) {
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.avatarSymbol = avatarSymbol
    }

    public var body: some View {
        TimelineView(AgentChatElapsedTickSchedule(start: startedAt)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(alignment: .center, spacing: DS.Space.sm) {
                BotsAvatarView(
                    name: snapshot.name,
                    handle: snapshot.handle,
                    symbol: avatarSymbol,
                    size: Self.chromeSize
                )
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(AgentPeerActivityPresentation.title(for: snapshot))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(titleColor)
                    Text(AgentPeerActivityPresentation.detail(
                        for: snapshot,
                        elapsedSeconds: seconds
                    ))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                stateIcon
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentPeerActivityPresentation.accessibilityLabel(
                for: snapshot,
                elapsedSeconds: seconds
            ))
            .accessibilityIdentifier("agent.peerActivity")
        }
    }

    private static let chromeSize: CGFloat = 22

    @ViewBuilder
    private var stateIcon: some View {
        switch snapshot.phase {
        case .waiting:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(DS.Palette.accent)
                .frame(width: Self.chromeSize, height: Self.chromeSize)
                .background(Circle().fill(DS.Palette.accent.opacity(0.16)))
                .accessibilityHidden(true)
        case .needsAttention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
                .frame(width: Self.chromeSize, height: Self.chromeSize)
                .accessibilityHidden(true)
        }
    }

    private var titleColor: Color {
        snapshot.phase == .needsAttention ? DS.Palette.danger : DS.Palette.text
    }
}

/// Shared thread rail chrome. Agent App and dest mount this so hide,
/// Clear All, +, and search stay one control.
public struct AgentChatThreadRail<Content: View>: View {
    public let title: String
    public let isEmpty: Bool
    public let emptySubtitle: String
    @Binding public var searchQuery: String
    public let hasSearchMatches: Bool
    public let onHide: () -> Void
    public let onClearAll: () -> Void
    public let onNew: () -> Void
    public var identifier: String
    public var hideIdentifier: String
    public var clearAllIdentifier: String
    public var newIdentifier: String
    public var searchIdentifier: String
    public var newHelp: String = AgentChatThreadRailCopy.newHelp
    public var showsTrailingHairline: Bool = false
    public var content: Content

    public init(
        title: String,
        isEmpty: Bool,
        emptySubtitle: String,
        searchQuery: Binding<String>,
        hasSearchMatches: Bool,
        identifier: String,
        hideIdentifier: String,
        clearAllIdentifier: String,
        newIdentifier: String,
        searchIdentifier: String,
        newHelp: String = AgentChatThreadRailCopy.newHelp,
        showsTrailingHairline: Bool = false,
        onHide: @escaping () -> Void,
        onClearAll: @escaping () -> Void,
        onNew: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isEmpty = isEmpty
        self.emptySubtitle = emptySubtitle
        self._searchQuery = searchQuery
        self.hasSearchMatches = hasSearchMatches
        self.identifier = identifier
        self.hideIdentifier = hideIdentifier
        self.clearAllIdentifier = clearAllIdentifier
        self.newIdentifier = newIdentifier
        self.searchIdentifier = searchIdentifier
        self.newHelp = newHelp
        self.showsTrailingHairline = showsTrailingHairline
        self.onHide = onHide
        self.onClearAll = onClearAll
        self.onNew = onNew
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeaderG(title) {
                HStack(spacing: Self.headerControlSpacing) {
                    hideButton
                        .padding(.horizontal, -DSIconButton.visualPackInset)
                    if AgentChatThreadRailCopy.showsClearAll(isEmpty: isEmpty) {
                        Button(AgentChatThreadRailCopy.clearAllTitle, action: onClearAll)
                            .buttonStyle(.plain)
                            .font(DS.Font.caption.weight(.medium))
                            .foregroundColor(DS.Palette.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier(clearAllIdentifier)
                            .help(AgentChatThreadRailCopy.clearAllHelp)
                    }
                    DSIconButton("plus", help: newHelp, action: onNew)
                        .padding(.horizontal, -DSIconButton.visualPackInset)
                        .accessibilityIdentifier(newIdentifier)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if isEmpty {
                DSEmptyState(
                    icon: AgentChatThreadRailCopy.emptyIcon,
                    title: AgentChatThreadRailCopy.emptyTitle,
                    subtitle: emptySubtitle
                )
            } else {
                searchBar
                if hasSearchMatches {
                    content
                } else {
                    Text(AgentChatThreadRailCopy.noMatchText(query: searchQuery))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .padding(DS.Space.sm)
                }
            }
        }
        .background(DS.Palette.surface)
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .trailing) {
            if showsTrailingHairline {
                Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
            }
        }
    }

    /// Gap between hide, Clear All, and +. Icons keep a 44pt hit box via
    /// `visualPackInset`; this spacing is the visible air between glyphs.
    private static var headerControlSpacing: CGFloat { DS.Space.md }

    private var hideButton: some View {
        DSIconButton("sidebar.left", help: AgentChatThreadRailCopy.hideHelp, action: onHide)
            .accessibilityIdentifier(hideIdentifier)
    }

    private var searchBar: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(AgentChatThreadRailCopy.searchPlaceholder, text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier(searchIdentifier)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AgentChatThreadRailCopy.clearSearchLabel)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
    }
}

/// Inline editor for one queued message: focused on open, grows with the text,
/// Esc cancels, Cmd-Return saves, and Save stays off until the text changes.
struct AgentQueuedMessageEditor: View {
    @Binding var text: String
    let original: String
    let allowsEmpty: Bool
    let position: Int
    let identifier: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) && (allowsEmpty || !trimmed.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            TextEditor(text: $text)
                .font(DS.Font.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, DS.Space.xs)
                .frame(minHeight: 72, maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .background(DS.Palette.bg)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(focused ? DS.Palette.accent : DS.Palette.line, lineWidth: DS.Border.hairline)
                )
                .onKeyPress(.escape) { onCancel(); return .handled }
                .accessibilityLabel("Edit queued message \(position)")
                .accessibilityIdentifier("agent.queued.editor.\(identifier)")
            HStack(spacing: DS.Space.sm) {
                Text(L("Esc to cancel · ⌘↩ to save"))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: DS.Space.sm)
                Button(L("Cancel"), action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("agent.queued.editCancel.\(identifier)")
                Button(L("Save"), action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .accessibilityIdentifier("agent.queued.editSave.\(identifier)")
            }
        }
        .onAppear { focused = true }
    }
}
