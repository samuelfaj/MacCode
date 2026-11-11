import CoreModel
import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum PetAtlasError: Error, Equatable {
    case missingResource(String)
    case invalidManifest(String)
    case invalidImage(String)
    case invalidFrame(state: PetAnimationState, index: Int)
}

enum PetIdleMicroAction: String, CaseIterable, Decodable, Sendable, Equatable {
    case blink
    case tail
    case ears

    static let restDelayRange: ClosedRange<TimeInterval> = 6...10

    static func select(_ roll: Int) -> PetIdleMicroAction {
        switch min(max(roll, 0), 99) {
        case 0..<65: return .blink
        case 65..<85: return .tail
        default: return .ears
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .blink: return 24
        case .tail: return 5
        case .ears: return 12
        }
    }
}

private struct PetIdleMicroManifest: Decodable {
    let actions: [PetIdleMicroAction]
    let frames: Int
    let visualBounds: PetAtlasManifest.Row.VisualBounds

    func validated(frameBounds: CGRect) throws -> Self {
        guard actions == PetIdleMicroAction.allCases,
              frames == 8,
              frameBounds.contains(visualBounds.rect) else {
            throw PetAtlasError.invalidManifest("invalid idle micro-action manifest")
        }
        return self
    }
}

struct PetAtlasManifest: Decodable, Equatable {
    struct Dimensions: Decodable, Equatable {
        let height: Int
        let width: Int
    }

    struct Grid: Decodable, Equatable {
        let columns: Int
        let frameHeight: Int
        let frameWidth: Int
        let origin: String
        let rows: Int
    }

    enum PlaybackMode: String, Decodable, Equatable {
        case loop
        case onceHold
        case onceThenWaiting
        case onceThenDerived
    }

    struct Row: Decodable, Equatable {
        struct VisualBounds: Decodable, Equatable {
            let height: Int
            let width: Int
            let x: Int
            let y: Int

            var rect: CGRect {
                CGRect(x: x, y: y, width: width, height: height)
            }
        }

        let canonicalFrame: Int
        let fps: Int
        let frames: Int
        let mode: PlaybackMode
        let row: Int
        let state: PetAnimationState
        let visualBounds: VisualBounds
    }

    let atlas: String
    let dimensions: Dimensions
    let fallbackState: PetAnimationState
    let grid: Grid
    let name: String
    let rows: [Row]
    let schemaVersion: Int

    var unusedFrameCount: Int {
        grid.columns * grid.rows - rows.reduce(0) { $0 + $1.frames }
    }

    func row(for state: PetAnimationState) -> Row? {
        rows.first { $0.state == state }
    }

    func validated() throws -> PetAtlasManifest {
        guard schemaVersion == 3 else {
            throw PetAtlasError.invalidManifest("schemaVersion must be 3")
        }
        guard dimensions == Dimensions(height: 7_072, width: 1_536) else {
            throw PetAtlasError.invalidManifest("atlas dimensions must be 1536x7072")
        }
        guard grid == Grid(columns: 8, frameHeight: 208, frameWidth: 192, origin: "top-left", rows: 34) else {
            throw PetAtlasError.invalidManifest("grid must be 8x34 with 192x208 top-left frames")
        }
        guard grid.columns * grid.frameWidth == dimensions.width,
              grid.rows * grid.frameHeight == dimensions.height else {
            throw PetAtlasError.invalidManifest("grid does not exactly cover atlas")
        }
        guard fallbackState == .idle else {
            throw PetAtlasError.invalidManifest("fallbackState must be idle")
        }
        guard rows.map(\.state) == PetAnimationState.allCases,
              rows.map(\.row) == Array(0..<grid.rows) else {
            throw PetAtlasError.invalidManifest("rows must match the stable 34-state atlas order")
        }
        for row in rows {
            let visualBounds = row.visualBounds.rect
            let frameBounds = CGRect(
                x: 0,
                y: 0,
                width: grid.frameWidth,
                height: grid.frameHeight
            )
            guard (1...grid.columns).contains(row.frames),
                  row.frames > row.canonicalFrame,
                  row.canonicalFrame >= 0,
                  row.fps > 0,
                  visualBounds.width > 0,
                  visualBounds.height > 0,
                  frameBounds.contains(visualBounds) else {
                throw PetAtlasError.invalidManifest("invalid playback metadata for \(row.state.rawValue)")
            }
        }
        guard rows.reduce(0, { $0 + $1.frames }) == 272, unusedFrameCount == 0 else {
            throw PetAtlasError.invalidManifest("atlas must contain exactly 272 authored frames")
        }
        return self
    }
}

struct PetAtlasFrame {
    let state: PetAnimationState
    let index: Int
    let image: CGImage
    let displayImage: CGImage
    let appKitImage: NSImage
    let interpolationQuality: CGInterpolationQuality = .none

    init(state: PetAnimationState, index: Int, image: CGImage, displayImage: CGImage) {
        self.state = state
        self.index = index
        self.image = image
        self.displayImage = displayImage
        self.appKitImage = NSImage(
            cgImage: displayImage,
            size: NSSize(width: displayImage.width, height: displayImage.height)
        )
    }

    /// Rendering entry point for AppKit/SwiftUI bridges. Pixel art must never be
    /// filtered when scaled to the configured pet size.
    func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.interpolationQuality = interpolationQuality
        context.draw(image, in: rect)
        context.restoreGState()
    }
}

/// Bundle-backed atlas runtime. The full atlas is resolved and metadata-checked,
/// but never decoded. Runtime frames come from per-state row PNGs so decoded image
/// memory stays bounded to the active row plus at most two adjacent rows.
@MainActor
final class PetAtlas {
    let manifest: PetAtlasManifest
    let atlasURL: URL

    private let rowURLs: [PetAnimationState: URL]
    private var rowImages: [PetAnimationState: CGImage] = [:]
    private var rowFrames: [PetAnimationState: [Int: PetAtlasFrame]] = [:]
    private let idleMicroManifest: PetIdleMicroManifest
    private let idleMicroRowURLs: [PetIdleMicroAction: URL]
    private var idleMicroRowImage: (action: PetIdleMicroAction, image: CGImage)?
    private var idleMicroFrames: [Int: PetAtlasFrame] = [:]

    var decodedRowStates: Set<PetAnimationState> { Set(rowImages.keys) }

    static func bundled() throws -> PetAtlas {
        let name = "remote-code-black-cat-atlas-v3"
        // WHY: never use SPM `Bundle.module` here — its static accessor
        // fatalErrors when the package layout is Contents/Resources (shipped
        // apps) and only a developer .build path remains. See AppShellResourceBundle.
        let resources = try AppShellResourceBundle.bundle()
        guard let manifestURL = resources.url(forResource: name, withExtension: "json", subdirectory: "Pet")
                ?? resources.url(forResource: name, withExtension: "json") else {
            throw PetAtlasError.missingResource("\(name).json")
        }
        return try PetAtlas(manifestURL: manifestURL)
    }

    // PERF: PetAtlas decodes two manifests per init (once per launch); share one decoder.
    private static let manifestDecoder = JSONDecoder()

    init(manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        self.manifest = try Self.manifestDecoder.decode(PetAtlasManifest.self, from: data).validated()

        let directory = manifestURL.deletingLastPathComponent()
        let atlasURL = directory.appendingPathComponent(manifest.atlas)
        guard FileManager.default.fileExists(atPath: atlasURL.path) else {
            throw PetAtlasError.missingResource(manifest.atlas)
        }
        try Self.validateImageMetadata(
            at: atlasURL,
            width: manifest.dimensions.width,
            height: manifest.dimensions.height
        )
        self.atlasURL = atlasURL

        let idleMicroManifestURL = directory
            .appendingPathComponent("remote-code-black-cat-idle-microactions.json")
        guard FileManager.default.fileExists(atPath: idleMicroManifestURL.path) else {
            throw PetAtlasError.missingResource(idleMicroManifestURL.lastPathComponent)
        }
        let idleMicroData = try Data(contentsOf: idleMicroManifestURL, options: .mappedIfSafe)
        self.idleMicroManifest = try Self.manifestDecoder.decode(
            PetIdleMicroManifest.self,
            from: idleMicroData
        ).validated(frameBounds: CGRect(
            x: 0,
            y: 0,
            width: manifest.grid.frameWidth,
            height: manifest.grid.frameHeight
        ))

        var idleMicroRows: [PetIdleMicroAction: URL] = [:]
        for action in PetIdleMicroAction.allCases {
            let filename = "remote-code-black-cat-idle-\(action.rawValue).png"
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PetAtlasError.missingResource(filename)
            }
            try Self.validateImageMetadata(
                at: url,
                width: manifest.dimensions.width,
                height: manifest.grid.frameHeight
            )
            idleMicroRows[action] = url
        }
        self.idleMicroRowURLs = idleMicroRows

        var rows: [PetAnimationState: URL] = [:]
        for state in PetAnimationState.allCases {
            let filename = "remote-code-black-cat-\(state.rawValue).png"
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PetAtlasError.missingResource(filename)
            }
            try Self.validateImageMetadata(
                at: url,
                width: manifest.dimensions.width,
                height: manifest.grid.frameHeight
            )
            rows[state] = url
        }
        self.rowURLs = rows
    }

    func rowURL(for state: PetAnimationState) throws -> URL {
        guard let url = rowURLs[state] else {
            throw PetAtlasError.missingResource("remote-code-black-cat-\(state.rawValue).png")
        }
        return url
    }

    func idleMicroActionRowURL(for action: PetIdleMicroAction) throws -> URL {
        guard let url = idleMicroRowURLs[action] else {
            throw PetAtlasError.missingResource("remote-code-black-cat-idle-\(action.rawValue).png")
        }
        return url
    }

    func idleMicroActionFrame(action: PetIdleMicroAction, index: Int) throws -> PetAtlasFrame {
        guard (0..<idleMicroManifest.frames).contains(index) else {
            throw PetAtlasError.invalidFrame(state: .idle, index: index)
        }
        if idleMicroRowImage?.action != action {
            idleMicroRowImage = (action, try decodeIdleMicroRow(action))
            idleMicroFrames.removeAll(keepingCapacity: true)
        }
        if let cached = idleMicroFrames[index] { return cached }
        guard let rowImage = idleMicroRowImage?.image else {
            throw PetAtlasError.invalidImage("idle-\(action.rawValue) row did not decode")
        }
        let rect = CGRect(
            x: index * manifest.grid.frameWidth,
            y: 0,
            width: manifest.grid.frameWidth,
            height: manifest.grid.frameHeight
        )
        let visualBounds = idleMicroManifest.visualBounds.rect
        guard let image = rowImage.cropping(to: rect),
              let displayImage = image.cropping(to: visualBounds) else {
            throw PetAtlasError.invalidFrame(state: .idle, index: index)
        }
        let frame = PetAtlasFrame(state: .idle, index: index, image: image, displayImage: displayImage)
        idleMicroFrames[index] = frame
        return frame
    }

    func canonicalIdleMicroActionFrame() throws -> PetAtlasFrame {
        try idleMicroActionFrame(action: .blink, index: 0)
    }

    func activate(_ state: PetAnimationState, adjacent: [PetAnimationState] = []) throws {
        if state != .idle {
            idleMicroRowImage = nil
            idleMicroFrames.removeAll(keepingCapacity: true)
        }
        var desired: [PetAnimationState] = [state]
        for candidate in adjacent where !desired.contains(candidate) && desired.count < 3 {
            desired.append(candidate)
        }
        let desiredSet = Set(desired)
        rowImages = rowImages.filter { desiredSet.contains($0.key) }
        rowFrames = rowFrames.filter { desiredSet.contains($0.key) }
        for candidate in desired where rowImages[candidate] == nil {
            rowImages[candidate] = try decodeRow(candidate)
        }
    }

    func frame(state: PetAnimationState, index: Int) throws -> PetAtlasFrame {
        guard let row = manifest.row(for: state), (0..<row.frames).contains(index) else {
            throw PetAtlasError.invalidFrame(state: state, index: index)
        }
        if rowImages[state] == nil {
            try activate(state)
        }
        if let cached = rowFrames[state]?[index] { return cached }
        guard let rowImage = rowImages[state] else {
            throw PetAtlasError.invalidImage("row did not decode for \(state.rawValue)")
        }
        let rect = CGRect(
            x: index * manifest.grid.frameWidth,
            y: 0,
            width: manifest.grid.frameWidth,
            height: manifest.grid.frameHeight
        )
        guard let image = rowImage.cropping(to: rect),
              image.width == manifest.grid.frameWidth,
              image.height == manifest.grid.frameHeight else {
            throw PetAtlasError.invalidFrame(state: state, index: index)
        }
        let visualBounds = row.visualBounds.rect
        guard let displayImage = image.cropping(to: visualBounds),
              displayImage.width == Int(visualBounds.width),
              displayImage.height == Int(visualBounds.height) else {
            throw PetAtlasError.invalidFrame(state: state, index: index)
        }
        let frame = PetAtlasFrame(
            state: state,
            index: index,
            image: image,
            displayImage: displayImage
        )
        rowFrames[state, default: [:]][index] = frame
        return frame
    }

    func canonicalFrame(for state: PetAnimationState) throws -> PetAtlasFrame {
        guard let row = manifest.row(for: state) else {
            throw PetAtlasError.invalidManifest("missing row for \(state.rawValue)")
        }
        return try frame(state: state, index: row.canonicalFrame)
    }

    private func decodeRow(_ state: PetAnimationState) throws -> CGImage {
        let url = try rowURL(for: state)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width == manifest.dimensions.width,
              image.height == manifest.grid.frameHeight,
              image.alphaInfo != .none,
              image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast else {
            throw PetAtlasError.invalidImage(url.lastPathComponent)
        }
        return image
    }

    private func decodeIdleMicroRow(_ action: PetIdleMicroAction) throws -> CGImage {
        let url = try idleMicroActionRowURL(for: action)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width == manifest.dimensions.width,
              image.height == manifest.grid.frameHeight,
              image.alphaInfo != .none,
              image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast else {
            throw PetAtlasError.invalidImage(url.lastPathComponent)
        }
        return image
    }

    private static func validateImageMetadata(at url: URL, width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (raw[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (raw[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth == width,
              pixelHeight == height else {
            throw PetAtlasError.invalidImage(url.lastPathComponent)
        }
    }
}
