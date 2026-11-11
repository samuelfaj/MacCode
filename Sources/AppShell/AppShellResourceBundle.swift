import CoreModel
import Foundation

/// Resolves the SwiftPM `RemoteCode_AppShell` resource bundle inside a real
/// `.app` package **without** using SPM's generated `Bundle.module`.
///
/// WHY: SwiftPM emits an accessor that only looks at:
///   1. `Bundle.main.bundleURL/RemoteCode_AppShell.bundle` (app root — wrong for
///      a standard Contents/Resources layout)
///   2. A **hardcoded** developer `.build/.../RemoteCode_AppShell.bundle` path
/// When either misses, the accessor `fatalError`s on first touch — uncatchable.
/// Developer machines still work because (2) exists; customers crash on launch
/// as soon as pet code loads the atlas (`petEnabled` defaults to true).
///
/// Pass criteria: find `Contents/Resources/RemoteCode_AppShell.bundle` first,
/// then other shipped candidates, then SPM build products for unit tests —
/// never call `Bundle.module` (it can abort the process).
enum AppShellResourceBundle {
    static let bundleFileName = "RemoteCode_AppShell.bundle"

    /// Returns the resource bundle or throws a catchable error.
    static func bundle(includeSwiftPMFallback: Bool = true) throws -> Bundle {
        if let found = locate(includeSwiftPMFallback: includeSwiftPMFallback) {
            return found
        }
        throw PetAtlasError.missingResource(bundleFileName)
    }

    /// Ordered candidates: packaged app first, then SPM test/build layouts.
    static func candidateURLs(
        main: Bundle = .main,
        fileManager: FileManager = .default,
        includeSwiftPMFallback: Bool = true
    ) -> [URL] {
        var urls: [URL] = []
        let name = bundleFileName

        if let resources = main.resourceURL {
            urls.append(resources.appendingPathComponent(name))
        }

        let mainURL = main.bundleURL
        // Standard macOS app: …/MacCode.app/Contents/Resources/…
        urls.append(
            mainURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(name)
        )
        // SPM-generated layout (also mirrored by package-app.sh as belt-and-suspenders)
        urls.append(mainURL.appendingPathComponent(name))

        if let exeDir = main.executableURL?.deletingLastPathComponent() {
            // …/Contents/MacOS → sibling Resources
            urls.append(
                exeDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(name)
            )
            // Next to the executable (swift test / .build product dirs)
            urls.append(exeDir.appendingPathComponent(name))
        }

        // Walk up from the executable looking for an SPM product bundle
        // (unit tests: xctest binary lives under .build/.../).
        if var dir = main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<12 {
                urls.append(dir.appendingPathComponent(name))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // Unit-test / local `swift test`: Bundle.main is the XCTest runner, not
        // our .app. Discover the package `.build` tree from this source file and
        // the process working directory so PetAtlas.bundled() keeps working
        // without ever touching the fatalError-prone Bundle.module accessor.
        if includeSwiftPMFallback {
            urls.append(contentsOf: swiftPMProductCandidateURLs(fileManager: fileManager))
        }

        // De-dupe while preserving order.
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }
    }

    /// `.build/<triple>/{debug,release}/RemoteCode_AppShell.bundle` candidates.
    static func swiftPMProductCandidateURLs(
        fileManager: FileManager = .default
    ) -> [URL] {
        let name = bundleFileName
        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

        // Sources/AppShell/AppShellResourceBundle.swift → package root (3 up).
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        roots.append(packageRoot)
        roots.append(packageRoot.appendingPathComponent(".build", isDirectory: true))

        var urls: [URL] = []
        for root in roots {
            urls.append(root.appendingPathComponent(name))
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                urls.append(child.appendingPathComponent(name))
                for config in ["debug", "release"] {
                    urls.append(
                        child
                            .appendingPathComponent(config, isDirectory: true)
                            .appendingPathComponent(name)
                    )
                }
            }
        }
        return urls
    }

    /// First-party Docker guest recipe (`Dockerfile` + start scripts).
    /// Prefer the packaged AppShell resource bundle; fall back to the
    /// source tree so Studio can build the base image (`BotComputerGuestSpec.imageTag`) in
    /// `swift test` and local checkouts without `Bundle.module`.
    static func computerGuestRecipeURL(
        fileManager: FileManager = .default
    ) -> URL? {
        resourceDirectoryURL(named: "ComputerGuest", containing: "Dockerfile", fileManager: fileManager)
    }

    /// In-guest agent kit (`bin/run-agent`, `bin/kill-agent`, vendored
    /// linux-use) that `BotGuestAgentKit` copies into `<AppSupport>/guest-tools`.
    static func guestAgentKitURL(
        fileManager: FileManager = .default
    ) -> URL? {
        resourceDirectoryURL(named: "GuestAgentKit", containing: "bin/run-agent", fileManager: fileManager)
    }

    /// A copied resource directory of the AppShell bundle, falling back to the
    /// source tree; `marker` must exist inside it.
    private static func resourceDirectoryURL(
        named name: String,
        containing marker: String,
        fileManager: FileManager
    ) -> URL? {
        var candidates: [URL] = []
        if let bundle = try? bundle() {
            if let url = bundle.url(forResource: name, withExtension: nil) {
                candidates.append(url)
            }
            if let resources = bundle.resourceURL {
                candidates.append(resources.appendingPathComponent(name))
            }
            candidates.append(bundle.bundleURL.appendingPathComponent(name))
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        candidates.append(source)

        var seen = Set<String>()
        for url in candidates {
            let path = url.standardizedFileURL.path
            if seen.contains(path) { continue }
            seen.insert(path)
            if fileManager.fileExists(atPath: url.appendingPathComponent(marker).path) {
                return url
            }
        }
        return nil
    }

    static func locate(
        main: Bundle = .main,
        fileManager: FileManager = .default,
        includeSwiftPMFallback: Bool = true
    ) -> Bundle? {
        for url in candidateURLs(
            main: main,
            fileManager: fileManager,
            includeSwiftPMFallback: includeSwiftPMFallback
        ) {
            let path = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // Must look like our resource bundle (directory ending in .bundle).
            guard path.hasSuffix(bundleFileName) else { continue }
            if let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }
}
