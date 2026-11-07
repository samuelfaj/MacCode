// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteCode",
    platforms: [
        .macOS(.v14),
        .iOS("18.0")
    ],
    products: [
        .executable(name: "RemoteCode", targets: ["AppShell"]),
        .executable(name: "RemoteCodeScheduledTaskAgent", targets: ["RemoteCodeScheduledTaskAgent"]),
        .executable(name: "RemoteCodeDistillService", targets: ["RemoteCodeDistillService"]),
        .executable(name: "RemoteCodeRunAsUserHelper", targets: ["RemoteCodeRunAsUserHelper"]),
        .executable(name: "LifecycleSignalProbe", targets: ["LifecycleSignalProbe"]),
        .executable(name: "rc2", targets: ["RC2CLI"]),
        .library(name: "CoreModel", targets: ["CoreModel"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "SocketServer", targets: ["SocketServer"]),
        .library(name: "Surfaces", targets: ["Surfaces"]),
        .library(name: "AppLifecycleSupport", targets: ["AppLifecycleSupport"]),
        .library(name: "DesignSystemKit", targets: ["DesignSystemKit"]),
        .library(name: "RemoteCodeTreaty", targets: ["RemoteCodeTreaty"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "RemoteCodeCSystem",
            path: "Sources/CSystem",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RemoteCodeTreaty",
            path: "Sources/RemoteCodeTreaty"
        ),
        .target(
            name: "CoreModel",
            path: "Sources/CoreModel",
            resources: [.copy("Resources/ChromeComputerUse")],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .target(
            name: "Persistence",
            dependencies: ["CoreModel"],
            path: "Sources/Persistence",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "AgentRuntime",
            dependencies: ["CoreModel", "Persistence", "RemoteCodeCSystem"],
            path: "Sources/AgentRuntime",
            resources: [
                .copy("Resources/remote-code-orchestrate")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "RemoteCodeScheduledTaskAgent",
            path: "Sources/RemoteCodeScheduledTaskAgent"
        ),
        .executableTarget(
            name: "RemoteCodeDistillService",
            dependencies: ["AgentRuntime", "Persistence"],
            path: "Sources/RemoteCodeDistillService"
        ),
        .executableTarget(
            name: "RemoteCodeRunAsUserHelper",
            path: "Sources/RemoteCodeRunAsUserHelper"
        ),
        .executableTarget(
            name: "LifecycleSignalProbe",
            dependencies: ["AppLifecycleSupport"],
            path: "Tests/LifecycleSignalProbe"
        ),
        .target(
            name: "SocketServer",
            dependencies: ["CoreModel", "Persistence", "AgentRuntime", "RemoteCodeTreaty"],
            path: "Sources/SocketServer"
        ),
        .target(
            name: "DesignSystemKit",
            path: "Sources/DesignSystemKit"
        ),
        .target(
            name: "AppLifecycleSupport",
            path: "Sources/AppLifecycleSupport"
        ),
        .target(
            name: "Surfaces",
            dependencies: ["CoreModel", "AgentRuntime", "Persistence", "RemoteCodeCSystem", "DesignSystemKit", "GhosttyKit"],
            path: "Sources/Surfaces",
            resources: [
                .copy("Resources/ghostty"),
                .process("Resources/SubagentCats")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedFramework("GameController")
            ]
        ),
        .executableTarget(
            name: "AppShell",
            dependencies: [
                "CoreModel",
                "Persistence",
                "AgentRuntime",
                "SocketServer",
                "RemoteCodeTreaty",
                "Surfaces",
                "AppLifecycleSupport",
                "DesignSystemKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AppShell",
            exclude: ["RemoteCode.entitlements"],
            resources: [
                .copy("Resources/Pet"),
                .copy("Resources/ComputerGuest"),
                .copy("Resources/GuestAgentKit")
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "RC2CLI",
            dependencies: ["CoreModel", "Persistence"],
            path: "Sources/RC2CLI"
        ),
        .testTarget(
            name: "CoreModelTests",
            dependencies: ["CoreModel"],
            path: "Tests/CoreModelTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "CoreModel"],
            path: "Tests/PersistenceTests"
        ),
        .target(
            name: "GitTestSupport",
            path: "Tests/GitTestSupport"
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "CoreModel", "GitTestSupport"],
            path: "Tests/AgentRuntimeTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "SocketServerTests",
            dependencies: ["SocketServer", "CoreModel", "Persistence", "RemoteCodeTreaty"],
            path: "Tests/SocketServerTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "SurfacesTests",
            dependencies: ["Surfaces", "CoreModel", "AgentRuntime", "GitTestSupport"],
            path: "Tests/SurfacesTests"
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "AppLifecycleSupport", "CoreModel", "Persistence", "RemoteCodeTreaty", "SocketServer", "Surfaces"],
            path: "Tests/AppShellTests"
        ),
        .testTarget(
            name: "DesignSystemKitTests",
            dependencies: ["DesignSystemKit"],
            path: "Tests/DesignSystemKitTests"
        ),
        .testTarget(
            name: "RemoteCodeTreatyTests",
            dependencies: ["RemoteCodeTreaty"],
            path: "Tests/RemoteCodeTreatyTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
