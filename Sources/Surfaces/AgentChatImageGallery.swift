import AppKit
import CoreModel
import DesignSystemKit
import ImageIO
import SwiftUI

// MARK: - Layout (pure)

/// Gallery geometry (contract §4): at most three tiles in a row; with more
/// images the third tile is dimmed and shows "+N", N being the images not shown.
public enum AgentChatImageGalleryLayout {
    public static let maxVisibleTiles = 3
    public static let tileHeight: CGFloat = 200
    public static let cornerRadius: CGFloat = 16
    public static let spacing: CGFloat = 8

    public struct Plan: Equatable {
        /// Tiles drawn (including the "+N" tile).
        public let visibleCount: Int
        /// Images hidden behind the "+N" tile; 0 when every image has a tile.
        public let overflowCount: Int
    }

    public static func plan(count: Int, expanded: Bool) -> Plan {
        let count = max(0, count)
        guard count > maxVisibleTiles, !expanded else { return Plan(visibleCount: count, overflowCount: 0) }
        return Plan(visibleCount: maxVisibleTiles, overflowCount: count - maxVisibleTiles)
    }

    /// Widest a tile may grow: one image reads large, three share the row.
    public static func tileMaxWidth(imageCount: Int) -> CGFloat {
        switch imageCount {
        case ...1: return 360
        case 2: return 280
        default: return 240
        }
    }
}

// MARK: - Loading

/// Off-main image loading for gallery tiles with a small decoded cache.
///
/// Local files (paths, `file://`, attachments) go through the shared
/// `AgentAttachmentThumbnailLoader` (ImageIO, downsampled, admission-bounded)
/// and are revalidated by size + mtime on every mount. https images are
/// fetched with URLSession under hard caps (image MIME only, 10 MB, 15 s).
actor AgentChatImageLoader {
    static let shared = AgentChatImageLoader()

    static let maxRemoteBytes = 10 * 1_024 * 1_024
    static let remoteTimeout: TimeInterval = 15
    static let decodeMaxPixel = 640
    /// A failed ref is not retried by every remount within this window.
    static let failureRetryInterval: TimeInterval = 30

    private final class Signature { let value: String; init(_ value: String) { self.value = value } }

    private static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    /// Last known content signature per local path, so a remount can paint
    /// the cached image on its first frame before revalidating.
    private static let localSignatures: NSCache<NSString, Signature> = {
        let cache = NSCache<NSString, Signature>()
        cache.countLimit = 256
        return cache
    }()

    private let session: URLSession
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    init(session: URLSession = AgentChatImageLoader.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = remoteTimeout
        configuration.timeoutIntervalForResource = remoteTimeout
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1_024 * 1_024, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }

    /// Cached image for the first frame of a remounted tile (main-thread safe).
    nonisolated static func cachedImage(for ref: AgentMessageImageRef) -> NSImage? {
        switch ref.source {
        case .remote(let url):
            return memory.object(forKey: url.absoluteString as NSString)
        case .attachment(_, let path), .localPath(let path):
            guard let signature = localSignatures.object(forKey: path as NSString) else { return nil }
            return memory.object(forKey: signature.value as NSString)
        }
    }

    func image(for ref: AgentMessageImageRef) async -> NSImage? {
        let key = Self.requestKey(ref)
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.failureRetryInterval { return nil }
        if let running = inFlight[key] { return await running.value }
        let session = session
        let task = Task.detached(priority: .userInitiated) { await Self.load(ref, session: session) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if image == nil {
            if failedAt.count > 512 { failedAt.removeAll() }
            failedAt[key] = Date()
        } else {
            failedAt[key] = nil
        }
        return image
    }

    private static func requestKey(_ ref: AgentMessageImageRef) -> String {
        switch ref.source {
        case .remote(let url): return "url:" + url.absoluteString
        case .attachment(_, let path), .localPath(let path): return "file:" + path
        }
    }

    private static func load(_ ref: AgentMessageImageRef, session: URLSession) async -> NSImage? {
        switch ref.source {
        case .remote(let url):
            let key = url.absoluteString as NSString
            if let cached = memory.object(forKey: key) { return cached }
            guard let data = await fetchRemote(url, session: session),
                  let decoded = decode(data, maxPixel: decodeMaxPixel) else { return nil }
            memory.setObject(decoded.image, forKey: key, cost: decoded.cost)
            return decoded.image
        case .attachment(_, let path), .localPath(let path):
            guard let signature = fileSignature(path) else { return nil }
            localSignatures.setObject(Signature(signature), forKey: path as NSString)
            if let cached = memory.object(forKey: signature as NSString) { return cached }
            guard let loaded = await AgentAttachmentThumbnailLoader.shared.transcriptThumbnail(forPath: path, featured: true) else {
                return nil
            }
            // The loader sizes the image in pixels, so size × 4 is its decoded cost.
            let cost = Int(loaded.image.size.width * loaded.image.size.height) * 4
            memory.setObject(loaded.image, forKey: signature as NSString, cost: max(1, cost))
            return loaded.image
        }
    }

    /// Path + size + mtime; attachment storage paths may have no extension.
    static func fileSignature(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(path)|\(size.int64Value)|\(modified.timeIntervalSince1970)"
    }

    /// Only successful image responses that are not announced as over the cap.
    nonisolated static func acceptsRemoteResponse(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return false }
        guard let mime = response.mimeType?.lowercased(), mime.hasPrefix("image/") else { return false }
        return response.expectedContentLength <= Int64(maxRemoteBytes)
    }

    static func fetchRemote(_ url: URL, session: URLSession) async -> Data? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: remoteTimeout)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard acceptsRemoteResponse(response) else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(maxRemoteBytes))))
            for try await byte in bytes {
                data.append(byte)
                // A server that lies about (or omits) its length is cut off at the cap.
                if data.count > maxRemoteBytes {
                    bytes.task.cancel()
                    return nil
                }
            }
            return data
        } catch {
            return nil
        }
    }

    nonisolated static func decode(_ data: Data, maxPixel: Int) -> (image: NSImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), image.width * image.height * 4)
    }
}

// MARK: - Gallery

/// The one image gallery for assistant replies (Agent App, Bot desk, turn
/// finals): a row of rounded aspect-fill tiles below the message text.
public struct AgentChatImageGallery: View, Equatable {
    public let refs: [AgentMessageImageRef]
    var tileHeight: CGFloat = AgentChatImageGalleryLayout.tileHeight

    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    public init(refs: [AgentMessageImageRef]) {
        self.refs = refs
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.refs == rhs.refs && lhs.tileHeight == rhs.tileHeight
    }

    private final class RefsBox { let refs: [AgentMessageImageRef]; init(_ refs: [AgentMessageImageRef]) { self.refs = refs } }
    private static let refsCache: NSCache<NSString, RefsBox> = {
        let cache = NSCache<NSString, RefsBox>()
        cache.countLimit = 512
        return cache
    }()

    /// Images a reply talks about, memoized by content: row bodies re-run on
    /// every transcript refresh and must not rescan the text each time.
    public static func refs(text: String, attachments: [AgentAttachment]) -> [AgentMessageImageRef] {
        let hasImageAttachment = attachments.contains(where: AgentMessageImageRefs.isImageAttachment)
        guard hasImageAttachment || AgentMessageImageRefs.mayContainTextReference(text) else { return [] }
        var hasher = Hasher()
        hasher.combine(attachments)
        let key = "\(AgentMessageMarkdown.cacheKey(for: text)):\(hasher.finalize())" as NSString
        if let cached = refsCache.object(forKey: key) { return cached.refs }
        let refs = AgentMessageImageRefs.extract(content: text, attachments: attachments)
        refsCache.setObject(RefsBox(refs), forKey: key)
        return refs
    }

    public var body: some View {
        let plan = AgentChatImageGalleryLayout.plan(count: refs.count, expanded: expanded)
        let shown = Array(refs.prefix(plan.visibleCount))
        let maxWidth = AgentChatImageGalleryLayout.tileMaxWidth(imageCount: min(refs.count, AgentChatImageGalleryLayout.maxVisibleTiles))
        VStack(alignment: .leading, spacing: AgentChatImageGalleryLayout.spacing) {
            ForEach(Array(stride(from: 0, to: shown.count, by: AgentChatImageGalleryLayout.maxVisibleTiles)), id: \.self) { start in
                HStack(spacing: AgentChatImageGalleryLayout.spacing) {
                    ForEach(shown[start..<min(start + AgentChatImageGalleryLayout.maxVisibleTiles, shown.count)], id: \.self) { ref in
                        let isOverflowTile = plan.overflowCount > 0 && ref == shown.last
                        AgentChatImageGalleryTile(
                            ref: ref,
                            overflowCount: isOverflowTile ? plan.overflowCount : 0,
                            height: tileHeight
                        ) {
                            if isOverflowTile {
                                expanded = true
                            } else {
                                open(ref)
                            }
                        }
                        .frame(maxWidth: maxWidth)
                    }
                    Spacer(minLength: 0)
                }
            }
            if expanded, refs.count > AgentChatImageGalleryLayout.maxVisibleTiles {
                Button(L("Show fewer images")) { expanded = false }
                    .buttonStyle(.plain)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.accent)
                    .accessibilityIdentifier("agent.imageGallery.collapse")
            }
        }
        .padding(.top, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel((refs.count == 1 ? L("%1$@ image", refs.count) : L("%1$@ images", refs.count)))
        .accessibilityIdentifier("agent.imageGallery")
    }

    /// Local images open in the Files split preview (the transcript's
    /// open-in-split route); web images open in the Browser split.
    private func open(_ ref: AgentMessageImageRef) {
        switch ref.source {
        case .remote(let url):
            openURL(url)
        case .attachment(_, let path), .localPath(let path):
            if let link = AgentMessageMarkdown.fileLinkURL(for: path) {
                openURL(link)
            }
        }
    }
}

struct AgentChatImageGalleryTile: View {
    let ref: AgentMessageImageRef
    var overflowCount: Int = 0
    var height: CGFloat = AgentChatImageGalleryLayout.tileHeight
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var failed = false

    init(ref: AgentMessageImageRef, overflowCount: Int = 0, height: CGFloat = AgentChatImageGalleryLayout.tileHeight, action: @escaping () -> Void) {
        self.ref = ref
        self.overflowCount = overflowCount
        self.height = height
        self.action = action
        // Cache-first: a remounted row paints its image on the first frame.
        _image = State(initialValue: AgentChatImageLoader.cachedImage(for: ref))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AgentChatImageGalleryLayout.cornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay { tileContent }
                .overlay {
                    if overflowCount > 0 {
                        ZStack {
                            Color.black.opacity(0.55)
                            Text(L("+%1$@", overflowCount))
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(overflowCount > 0 ? (overflowCount == 1 ? L("Show %1$@ more image", overflowCount) : L("Show %1$@ more images", overflowCount)) : L("Open %1$@", ref.displayName))
        .accessibilityLabel(overflowCount > 0 ? L("%1$@ more images", overflowCount) : L("Image %1$@", ref.displayName))
        .accessibilityHint(overflowCount > 0 ? L("Shows every image") : L("Opens the image"))
        .accessibilityIdentifier("agent.imageGallery.tile")
        .dsPointingHandCursor()
        .task(id: ref) { await load() }
    }

    @ViewBuilder
    private var tileContent: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .transition(.opacity)
        } else if failed {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .regular))
                Text(L("Image unavailable"))
                    .font(DS.Font.caption)
            }
            .foregroundColor(DS.Palette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.surface)
        } else {
            AgentChatImageShimmer()
        }
    }

    @MainActor
    private func load() async {
        let loaded = await AgentChatImageLoader.shared.image(for: ref)
        guard !Task.isCancelled else { return }
        if let loaded {
            failed = false
            guard loaded !== image else { return }
            let animate = image == nil && !reduceMotion
            withAnimation(animate ? .easeOut(duration: 0.18) : nil) { image = loaded }
        } else {
            image = nil
            failed = true
        }
    }
}

/// Fixed-size loading placeholder; the sweep stops under Reduce Motion.
private struct AgentChatImageShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.6

    var body: some View {
        DS.Palette.surface
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.06), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width)
                    }
                }
            }
            .clipped()
            .accessibilityLabel(L("Loading image"))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}
