import Foundation

/// Finds a SwiftPM resource bundle (`RemoteCode_<Target>.bundle`) without the
/// generated `Bundle.module` accessor, which `fatalError`s in the packaged app
/// when the bundle is not at the app root or the developer `.build` path.
/// Order: the app's Contents/Resources, next to the executable, then the
/// package `.build` products so `swift test` keeps working.
public enum PackagedResourceBundle {
    public static func bundle(target: String) -> Bundle? {
        let name = "RemoteCode_\(target).bundle"
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL { urls.append(resources.appendingPathComponent(name)) }
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"))
        urls.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if var dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(dir.deletingLastPathComponent().appendingPathComponent("Resources/\(name)"))
            for _ in 0..<8 {
                urls.append(dir.appendingPathComponent(name))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        let packageBuild = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build")
        for products in ["out/Products/Debug", "out/Products/Release", "debug", "release",
                         "arm64-apple-macosx/debug", "arm64-apple-macosx/release"] {
            urls.append(packageBuild.appendingPathComponent(products).appendingPathComponent(name))
        }
        return urls.lazy.compactMap { Bundle(url: $0) }.first
    }
}
