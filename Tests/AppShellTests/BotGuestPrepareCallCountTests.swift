import XCTest
import os
import AgentRuntime
@testable import CoreModel
import Persistence
import SocketServer
@testable import AppShell

/// A Docker daemon scripted at the command line. Every element of `launches`
/// is one `docker` process the app would have spawned.
private final class ScriptedDockerDaemon: @unchecked Sendable {
    struct Image {
        var id: String
        var labels: [String: String]
    }

    struct Container {
        var running: Bool
        var imageID: String
        var networks: [String]
        var labels: [String: String]
    }

    static let png = BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)

    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var builds = 0
    var images: [String: Image] = [:]
    var containers: [String: Container] = [:]
    var networks: Set<String> = []
    /// The daemon stopped answering: every command fails as the real CLI's does.
    var down = false
    var architecture = "aarch64"
    /// No desktop comes up: every screenshot fails.
    var screenDown = false
    /// Runs when a `docker stop` arrives, while its container is still running.
    var beforeStop: (() throws -> Void)?

    var launches: [[String]] { lock.withLock { recorded } }
    func forgetLaunches() { lock.withLock { recorded.removeAll() } }

    func run(_ args: [String]) throws -> Data {
        lock.withLock { recorded.append(args) }
        if down {
            throw args.first == "info"
                ? BotComputerDockerError.daemonUnavailable
                : BotComputerDockerError.provisioningFailed
        }
        let last = args.last ?? ""
        switch args.first {
        case "info":
            return Data("Server Version: 29.4.0\n Architecture: \(architecture)\n".utf8)
        case "image":
            return try inspectImages(args)
        case "inspect":
            return try inspect(format: args[2], name: args[3])
        case "network":
            if args[1] == "create" {
                guard networks.insert(last).inserted else { throw BotComputerDockerError.provisioningFailed }
            } else if args[1] == "inspect" {
                guard networks.contains(last) else { throw BotComputerDockerError.provisioningFailed }
            }
            return Data()
        case "build":
            // Docker's layer cache: an unchanged recipe (the digest label)
            // builds to the image the tag already has.
            let tag = value(after: "-t", in: args) ?? ""
            let stamped = labels(in: args)
            if images[tag]?.labels != stamped {
                builds += 1
                images[tag] = Image(id: "sha256:built-\(builds)", labels: stamped)
            }
            return Data()
        case "create":
            let name = value(after: "--name", in: args) ?? ""
            containers[name] = Container(
                running: false,
                imageID: images[last]?.id ?? "",
                networks: value(after: "--network", in: args).map { [$0] } ?? [],
                labels: labels(in: args)
            )
            return Data(name.utf8)
        case "start":
            containers[last]?.running = true
            return Data()
        case "stop":
            try beforeStop?()
            containers[last]?.running = false
            return Data()
        case "rename":
            containers[last] = containers.removeValue(forKey: args[1])
            return Data()
        case "rm":
            containers[last] = nil
            return Data()
        case "ps":
            // `ps -aq --filter name=^/<name>$`: an id when that container exists.
            let exists = containers.keys.contains { last == "name=^/\($0)$" }
            return Data((exists ? "id\n" : "").utf8)
        case "exec":
            // The screenshot; any other exec (the tools probe) prints nothing.
            guard args.contains("import") else { return Data() }
            if screenDown { throw BotComputerDockerError.provisioningFailed }
            return Self.png
        default:
            return Data()
        }
    }

    /// `docker image inspect`. With a format it prints one line per image that
    /// exists; the real CLI's runner keeps that output when another tag has no
    /// image and docker exits non-zero.
    private func inspectImages(_ args: [String]) throws -> Data {
        guard args.starts(with: ["image", "inspect", "-f"]) else {
            guard images[args[2]] != nil else { throw BotComputerDockerError.provisioningFailed }
            return Data("[]".utf8)
        }
        var lines: [String] = []
        for tag in args.dropFirst(4) {
            guard let image = images[tag] else { continue }
            let tags = String(decoding: try JSONEncoder().encode([tag]), as: UTF8.self)
            let labels = String(decoding: try JSONEncoder().encode(image.labels), as: UTF8.self)
            lines.append("\(tags)\t\(image.id)\t\(labels)")
        }
        guard !lines.isEmpty else { throw BotComputerDockerError.provisioningFailed }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// `docker inspect -f <format> <name>`: an image's id, one image label, or a container.
    private func inspect(format: String, name: String) throws -> Data {
        if format == "{{.Id}}" {
            guard let image = images[name] else { throw BotComputerDockerError.provisioningFailed }
            return Data(image.id.utf8)
        }
        if format.hasPrefix("{{index .Config.Labels") {
            guard let image = images[name] else { throw BotComputerDockerError.provisioningFailed }
            let key = format.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
            return Data((image.labels[key] ?? "").utf8)
        }
        guard let container = containers[name] else { throw BotComputerDockerError.provisioningFailed }
        let labels = String(decoding: try JSONEncoder().encode(container.labels), as: UTF8.self)
        let networks = container.networks.map { $0 + "," }.joined()
        return Data("\(container.running) \(container.imageID) 49152 \(networks) \(labels)\n\n".utf8)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    private func labels(in args: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for (index, arg) in args.enumerated() where arg == "--label" {
            let pair = args[index + 1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            found[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
        }
        return found
    }
}

/// The Mac distill binary the resolver is told about.
private let hostDistill = "/usr/local/bin/distill"

private final class GatedGuestVM: BotGuestVMPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    var error: Error?
    let gate = DispatchSemaphore(value: 0)

    var calls: Int { lock.withLock { entered } }

    func prepare(
        botID: BotID, threadID: AgentThreadID, workspace: String?, registeredWorkspaces: Set<String>
    ) throws -> BotGuestVM {
        lock.withLock { entered += 1 }
        gate.wait()
        if let error { throw error }
        return BotGuestVM(container: "remotecode-bot-test", dockerArch: "aarch64", mountedWorkspaces: [])
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

/// C10 (P1-02, P1-13): what a send to a bot with a Docker desktop costs
/// before its agent starts. Counted in `docker` processes and in which steps
/// overlap, never in milliseconds.
@MainActor
final class BotGuestPrepareCallCountTests: XCTestCase {
    private var root: URL!
    private var gateways: [BotGuestMCPGateway] = []

    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        // Resolved: a workspace path is only mounted when it has no symlink in it (/var → /private/var).
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("RC2GuestPrepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        gateways.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Docker calls per send (P1-02)

    private struct Guest {
        let daemon: ScriptedDockerDaemon
        let docker: BotComputerDockerCLI
        let service: BotComputerGuestService
        let support: URL
        let recipe: URL
        let botID: BotID

        var container: String { BotComputerGuestSpec.containerName(botID: botID) }
    }

    /// A bot whose container is running on its own network, from the current
    /// image and the current create options: what every send after the first finds.
    private func makeRunningGuest(workspaces: [String] = []) throws -> Guest {
        let support = root.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
        let recipe = root.appendingPathComponent("recipe", isDirectory: true)
        try FileManager.default.createDirectory(at: recipe, withIntermediateDirectories: true)
        try "FROM scratch\n".write(to: recipe.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        let botID = BotID()
        let network = BotComputerGuestSpec.networkName(botID: botID)
        let daemon = ScriptedDockerDaemon()
        daemon.images[BotComputerGuestSpec.imageTag] = .init(id: "sha256:base", labels: [
            BotComputerGuestSpec.recipeLabelKey: BotComputerGuestSpec.recipeRevision,
            BotComputerGuestSpec.recipeDigestLabelKey: BotComputerGuestSpec.recipeDigest(context: recipe),
        ])
        daemon.networks = [network]
        daemon.containers[BotComputerGuestSpec.containerName(botID: botID)] = .init(
            running: true, imageID: "sha256:base", networks: [network],
            labels: [
                BotComputerGuestSpec.workspacesLabelKey: BotComputerGuestSpec.workspacesLabel(workspaces),
                BotComputerGuestSpec.runtimeLabelKey: BotComputerGuestSpec.runtimeRevision,
            ]
        )
        if !workspaces.isEmpty {
            let manifest = BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID)
            try FileManager.default.createDirectory(
                at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspaces).write(to: manifest)
        }
        let docker = BotComputerDockerCLI(run: { try daemon.run($0) })
        let service = BotComputerGuestService(
            appSupport: support, docker: docker, recipeContext: recipe,
            observeAttempts: 1, observeDelay: 0, vmRuns: BotVMRunRegistry()
        )
        return Guest(
            daemon: daemon, docker: docker, service: service, support: support, recipe: recipe, botID: botID
        )
    }

    private func makeVM(_ guest: Guest, rememberingArchitecture: Bool = true) -> BotGuestDockerVM {
        guard rememberingArchitecture else {
            return BotGuestDockerVM(appSupport: guest.support, docker: guest.docker, service: guest.service)
        }
        return BotGuestDockerVM(
            appSupport: guest.support, docker: guest.docker, service: guest.service,
            resolveExecutable: { "/usr/local/bin/docker" }
        )
    }

    @discardableResult
    private func prepare(_ vm: BotGuestDockerVM, _ guest: Guest, workspace: String? = nil) throws -> BotGuestVM {
        try vm.prepare(
            botID: guest.botID, threadID: AgentThreadID(),
            workspace: workspace, registeredWorkspaces: Set([workspace].compactMap { $0 })
        )
    }

    private func verbs(_ guest: Guest) -> [String] {
        guest.daemon.launches.map { launch in
            switch launch.first {
            case "image", "network": return launch.prefix(2).joined(separator: " ")
            case "exec": return launch.contains("import") ? "screenshot" : "exec"
            default: return launch.first ?? ""
            }
        }
    }

    func test_aSendToARunningCurrentGuest_spawnsAtMostThreeDockerProcesses_andTakesNoScreenshot() throws {
        // WHY (P1-02): a guest agent ends with its turn, so every message to a
        // Docker-desktop bot prepares the container again. With the container
        // already running and current that was 11 or 12 serial `docker`
        // processes, one of them a full-screen PNG of the guest, before the
        // agent could start. The checks stay; Docker is asked fewer times.
        let guest = try makeRunningGuest()
        let vm = makeVM(guest, rememberingArchitecture: false)
        try prepare(vm, guest) // the first prepare also probes the image's tools, once per container image
        guest.daemon.forgetLaunches()

        let prepared = try prepare(vm, guest)

        XCTAssertEqual(prepared, BotGuestVM(container: guest.container, dockerArch: "aarch64", mountedWorkspaces: []))
        XCTAssertLessThanOrEqual(guest.daemon.launches.count, 3, "\(verbs(guest))")
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"])
        XCTAssertEqual(guest.daemon.launches.dropFirst().first, [
            "image", "inspect", "-f", "{{json .RepoTags}}\t{{.Id}}\t{{json .Config.Labels}}",
            BotComputerGuestSpec.imageTag, BotComputerGuestSpec.botImageTag(botID: guest.botID),
        ], "the base image and the bot's own image are read in one inspect")
    }

    func test_sameExecutableDaemonArchitectureSwitchUsesCurrentArchitectureOnRunningGuest() throws {
        // WHY: Docker context can switch daemon CPU architecture without
        // changing the executable or the already-running container.
        let guest = try makeRunningGuest()
        let vm = makeVM(guest)
        XCTAssertEqual(try prepare(vm, guest).dockerArch, "aarch64")

        guest.daemon.architecture = "x86_64"
        guest.daemon.forgetLaunches()
        let prepared = try prepare(vm, guest)

        XCTAssertEqual(prepared.container, guest.container)
        XCTAssertEqual(prepared.dockerArch, "x86_64")
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"])
    }

    func test_anOutdatedImageNetworkOrLabelStillReplacesTheContainer_andANewContainerIsStillScreenshotted() throws {
        // WHY: the short path must not skip a freshness check. Anything that
        // made the old path recreate the container still does, and a container
        // this call created is still proven by a screenshot before the agent
        // is started in it.
        try assertReplaced("an image rebuilt under the same tag") { guest in
            guest.daemon.images[BotComputerGuestSpec.imageTag]?.id = "sha256:rebuilt"
        }
        try assertReplaced("a container on another network") { guest in
            guest.daemon.containers[guest.container]?.networks = ["bridge"]
        }
        try assertReplaced("a container from older create options") { guest in
            guest.daemon.containers[guest.container]?.labels[BotComputerGuestSpec.runtimeLabelKey] = "1"
        }
        try assertReplaced("a base image built from another recipe") { guest in
            guest.daemon.images[BotComputerGuestSpec.imageTag]?
                .labels[BotComputerGuestSpec.recipeDigestLabelKey] = "another-recipe"
        }
        try assertReplaced("the bot's own image, built after its container") { guest in
            guest.daemon.images[BotComputerGuestSpec.botImageTag(botID: guest.botID)] = .init(
                id: "sha256:own",
                labels: [BotComputerGuestSpec.recipeLabelKey: BotComputerGuestSpec.recipeRevision]
            )
        }
    }

    private func assertReplaced(_ what: String, _ outdate: (Guest) -> Void, line: UInt = #line) throws {
        let guest = try makeRunningGuest()
        let vm = makeVM(guest)
        try prepare(vm, guest)
        outdate(guest)
        guest.daemon.forgetLaunches()

        XCTAssertEqual(try prepare(vm, guest).container, guest.container, what, line: line)

        let replaced = verbs(guest)
        for verb in ["rm", "create", "start"] {
            XCTAssertTrue(replaced.contains(verb), "\(what) must still be replaced: \(replaced)", line: line)
        }
        XCTAssertTrue(replaced.contains("screenshot"), "\(what): a new container is still screenshotted: \(replaced)", line: line)
        // The replacement is current: the next send is the short one.
        guest.daemon.forgetLaunches()
        try prepare(vm, guest)
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"], what, line: line)
    }

    func test_aStoppedGuestIsStartedAndScreenshotted_andOnlyThenTakesTheShortPath() throws {
        // WHY: the screenshot is what proves a desktop this call started is
        // up. It is skipped only for a container that was already running.
        let guest = try makeRunningGuest()
        let vm = makeVM(guest)
        try prepare(vm, guest)
        guest.daemon.containers[guest.container]?.running = false
        guest.daemon.forgetLaunches()

        try prepare(vm, guest)

        // The short check (3 launches, including `docker info`) comes first
        // and the path every send took before follows whole: a send that is not short costs 2 more
        // launches than it did. Pinned so that cost cannot grow unseen.
        XCTAssertEqual(verbs(guest), [
            "info", "image inspect", "inspect",
            "image inspect", "inspect", "inspect", "network create", "network inspect",
            // `update` sets the always-on restart policy on older containers (2026-10-19).
            "image inspect", "inspect", "inspect", "update", "start", "screenshot", "inspect",
        ], "a stopped container is started and screenshotted, not recreated")
        guest.daemon.forgetLaunches()
        try prepare(vm, guest)
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"])
    }

    func test_aContainerAMountRestarted_isScreenshottedOnceBeforeTheShortPathTrustsIt() throws {
        // WHY: before a send, the preflight mounts a thread's folder by
        // replacing the bot's container, on its own service instance and with
        // no screenshot. The short path skips the screenshot only for a
        // desktop already seen up; taking that replacement for one would turn
        // "Could not start the Linux desktop" into a vague failure of the
        // agent's exec.
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let guest = try makeRunningGuest()
        let vm = makeVM(guest)
        try prepare(vm, guest)
        guest.daemon.forgetLaunches()
        let preflight = BotComputerGuestService(
            appSupport: guest.support, docker: guest.docker, recipeContext: guest.recipe,
            observeAttempts: 1, observeDelay: 0, vmRuns: BotVMRunRegistry()
        )
        try preflight.ensureWorkspaceMounted(
            botID: guest.botID, workspace: project.path, registered: [project.path]
        )
        let mounted = verbs(guest)
        XCTAssertTrue(mounted.contains("create") && mounted.contains("start"), "\(mounted)")
        XCTAssertFalse(mounted.contains("screenshot"), "the mount itself proves nothing: \(mounted)")
        guest.daemon.forgetLaunches()

        XCTAssertEqual(try prepare(vm, guest, workspace: project.path).mountedWorkspaces, [project.path])

        let proven = verbs(guest)
        XCTAssertTrue(proven.contains("screenshot"), "a container nothing has screenshotted yet: \(proven)")
        XCTAssertFalse(proven.contains("create") || proven.contains("rm"), "it is proven, not replaced again: \(proven)")
        guest.daemon.forgetLaunches()
        try prepare(vm, guest, workspace: project.path)
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"], "proven once, then short")
    }

    func test_aContainerAFailedRebuildRestarted_isScreenshottedOnceBeforeTheShortPathTrustsIt() throws {
        // WHY: a rebuild stops the bot's desktop before it starts the new
        // one, so two Chromiums never write one profile. When the new one
        // does not come up, the old container is started again with no
        // screenshot. Rebuilding an unchanged recipe gives the same image, so
        // that container is still current: the short path would take it for
        // a desktop already seen up and start the agent in one nobody saw
        // come back.
        let guest = try makeRunningGuest()
        let ownTag = BotComputerGuestSpec.botImageTag(botID: guest.botID)
        _ = try guest.service.rebuild(botID: guest.botID)
        let ownImage = try XCTUnwrap(guest.daemon.images[ownTag]?.id)
        let vm = makeVM(guest)
        guest.daemon.forgetLaunches()
        try prepare(vm, guest)
        XCTAssertFalse(verbs(guest).contains("screenshot"), "a successful rebuild leaves its desktop proven")
        guest.daemon.forgetLaunches()
        try prepare(vm, guest)
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"], "a rebuilt desktop was proven: its sends are short")

        guest.daemon.screenDown = true
        guest.daemon.forgetLaunches()
        XCTAssertThrowsError(try guest.service.rebuild(botID: guest.botID))
        guest.daemon.screenDown = false

        let rolledBack = guest.daemon.launches
        XCTAssertTrue(rolledBack.contains(["stop", guest.container]), "\(verbs(guest))")
        XCTAssertEqual(rolledBack.last, ["start", guest.container], "started again, and nothing screenshots it")
        XCTAssertEqual(guest.daemon.containers[guest.container]?.imageID, ownImage)
        XCTAssertEqual(
            guest.daemon.images[ownTag]?.id, ownImage,
            "an unchanged recipe builds to the same image, so the old container is still current"
        )
        guest.daemon.forgetLaunches()

        try prepare(vm, guest)

        let proven = verbs(guest)
        XCTAssertTrue(proven.contains("screenshot"), "a desktop nothing has screenshotted since its restart: \(proven)")
        XCTAssertNotEqual(proven, ["image inspect", "inspect"])
        XCTAssertFalse(proven.contains("create") || proven.contains("rm"), "it is proven, not replaced: \(proven)")
        guest.daemon.forgetLaunches()
        try prepare(vm, guest)
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"], "proven once, then short")
    }

    func test_aScreenshotTakenWhileARebuildStopsTheContainer_doesNotProveTheOneStartedAgain() throws {
        // WHY: opening the bot's desktop screenshots its container whether or
        // not a rebuild is under way. One taken just before the rebuild stops
        // that container shows a desktop about to go down. It must not count
        // for the container a failed rebuild starts again after it.
        let guest = try makeRunningGuest()
        _ = try guest.service.rebuild(botID: guest.botID)
        let vm = makeVM(guest)
        try prepare(vm, guest)
        guest.daemon.beforeStop = {
            _ = try guest.service.provision(botID: guest.botID)
            guest.daemon.screenDown = true
        }
        guest.daemon.forgetLaunches()
        XCTAssertThrowsError(try guest.service.rebuild(botID: guest.botID))
        guest.daemon.beforeStop = nil
        guest.daemon.screenDown = false
        XCTAssertEqual(
            verbs(guest).filter { $0 == "screenshot" }.count, 2,
            "one of the running desktop as it is stopped, one the new container fails: \(verbs(guest))"
        )
        XCTAssertEqual(guest.daemon.launches.last, ["start", guest.container], "started again, and nothing screenshots it")
        guest.daemon.forgetLaunches()

        try prepare(vm, guest)

        let proven = verbs(guest)
        XCTAssertTrue(proven.contains("screenshot"), "its only screenshot predates its restart: \(proven)")
        XCTAssertFalse(proven.contains("create") || proven.contains("rm"), "it is proven, not replaced: \(proven)")
    }

    func test_aContainerStartedWhoseScreenshotFailed_isScreenshottedAgainBeforeTheShortPathTrustsIt() throws {
        // WHY: a send that starts or creates the container and gets no
        // screenshot fails with the desktop's own error, and leaves the
        // container running. The next send must ask for the screenshot again,
        // as every send did before the short path, instead of taking a
        // desktop that never showed its screen for one already seen up.
        try assertProvenAfterAFailedScreenshot("a stopped container started again") { guest in
            guest.daemon.containers[guest.container]?.running = false
        }
        try assertProvenAfterAFailedScreenshot("a container created in place of an outdated one") { guest in
            guest.daemon.images[BotComputerGuestSpec.imageTag]?.id = "sha256:rebuilt"
        }
    }

    private func assertProvenAfterAFailedScreenshot(
        _ what: String, _ change: (Guest) -> Void, line: UInt = #line
    ) throws {
        let guest = try makeRunningGuest()
        let vm = makeVM(guest)
        try prepare(vm, guest)
        change(guest)
        guest.daemon.screenDown = true
        XCTAssertThrowsError(try prepare(vm, guest), what, line: line)
        guest.daemon.screenDown = false
        XCTAssertEqual(guest.daemon.containers[guest.container]?.running, true, what, line: line)
        guest.daemon.forgetLaunches()

        try prepare(vm, guest)

        let proven = verbs(guest)
        XCTAssertTrue(proven.contains("screenshot"), "\(what): no screenshot has proven it yet: \(proven)", line: line)
        XCTAssertFalse(
            proven.contains("create") || proven.contains("rm"),
            "\(what): it is proven, not replaced again: \(proven)", line: line
        )
        guest.daemon.forgetLaunches()
        try prepare(vm, guest)
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"], what, line: line)
    }

    func test_aBoundFolderThatWasDeleted_isDroppedNotMountedAgain_andTheSendStillSaysItIsNotMounted() throws {
        // WHY: Docker creates a missing bind source as an empty folder. A
        // send from a thread whose folder was deleted used to drop the bind
        // and fail with "...is not inside a folder mounted in the bot's Linux
        // VM". The short check must leave the manifest alone, or the old path
        // no longer finds the folder in it and mounts the deleted path again.
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let guest = try makeRunningGuest(workspaces: [project.path])
        let vm = makeVM(guest)
        try prepare(vm, guest, workspace: project.path)
        try FileManager.default.removeItem(at: project)
        guest.daemon.forgetLaunches()

        let prepared = try prepare(vm, guest, workspace: project.path)

        XCTAssertEqual(prepared.mountedWorkspaces, [])
        let creates = guest.daemon.launches.filter { $0.first == "create" }
        XCTAssertEqual(creates.count, 1, "\(verbs(guest))")
        XCTAssertFalse(
            creates.contains { $0.contains { $0.contains(project.path) } },
            "the deleted folder must not be bound again: \(creates)"
        )
        // The short check, then exactly what this send launched before (the
        // last one is the tools probe of a new container).
        XCTAssertEqual(verbs(guest), [
            "info", "image inspect", "inspect",
            "inspect", "image inspect", "inspect", "inspect", "network create", "network inspect",
            "image inspect", "inspect", "rm", "create", "start", "screenshot", "inspect", "exec",
        ])
        XCTAssertThrowsError(try BotGuestRunResolver.guestCwd(
            requestCwd: project.path, workspace: project.path, mounted: prepared.mountedWorkspaces
        )) { error in
            XCTAssertEqual(error as? DistillGuestLaunchError, .unavailable(
                "this conversation's folder \(project.path) is not inside a folder mounted in the bot's Linux VM."
            ))
        }
    }

    func test_aDaemonThatWentDownStillFailsAsDockerNotRunning_andNothingElseIsTried() throws {
        // WHY: `docker info` is what names a daemon that is down ("Docker is
        // not running. Start Docker..."). Remembering the architecture must
        // not turn that into a build attempt and a vaguer error.
        let guest = try makeRunningGuest()
        let vm = makeVM(guest)
        try prepare(vm, guest)
        guest.daemon.down = true
        guest.daemon.forgetLaunches()

        XCTAssertThrowsError(try prepare(vm, guest)) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .daemonUnavailable)
        }
        XCTAssertEqual(verbs(guest), ["info"])
    }

    func test_aWorkspaceThreadWithItsFolderMountedIsAsShort_andAnUnmountedFolderIsNotWavedThrough() throws {
        // WHY: a workspace thread's send checked the mount with its own
        // inspect before the rest. The mount check stays (a folder that is not
        // bound in the container must still be remounted), without a third
        // look at the same container.
        let project = root.appendingPathComponent("project", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        for folder in [project, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let guest = try makeRunningGuest(workspaces: [project.path])
        let vm = makeVM(guest)
        try prepare(vm, guest, workspace: project.path)
        guest.daemon.forgetLaunches()

        XCTAssertEqual(try prepare(vm, guest, workspace: project.path).mountedWorkspaces, [project.path])
        XCTAssertEqual(verbs(guest), ["info", "image inspect", "inspect"])

        XCTAssertNil(try guest.service.runningCurrentContainer(
            botID: guest.botID, workspace: other.path,
            registered: [project.path, other.path], requestingThreadID: nil
        ), "a folder the container does not bind goes through ensureWorkspaceMounted")
    }

    func test_oneImageInspectAnswersForEveryTag_andALineItCannotAttributeIsNotReadAsAMissingImage() throws {
        // WHY: the single inspect prints nothing for a tag with no image, so
        // each line has to say which tag it answers for. Reading an
        // unattributed line as "the bot has no image of its own" would keep a
        // container built from an older image.
        let both = BotComputerDockerCLI { _ in
            Data("[\"docker.io/a:1\"]\tsha256:a\t{\"k\":\"v\"}\n[\"b:1\",\"b:2\"]\tsha256:b\tnull\n".utf8)
        }
        XCTAssertEqual(try both.imageStates(tags: ["a:1", "b:2", "c:1"]), [
            "a:1": BotComputerImageState(id: "sha256:a", labels: ["k": "v"]),
            "b:2": BotComputerImageState(id: "sha256:b"),
        ])
        let unattributed = BotComputerDockerCLI { _ in Data("[\"other:1\"]\tsha256:a\t{}\n".utf8) }
        XCTAssertThrowsError(try unattributed.imageStates(tags: ["a:1", "b:2"]))
    }

    func test_whatDockerPrintedBeforeExitingNonZeroForAMissingTag_isTheAnswer_forThatInspectOnly() throws {
        // WHY: a bot normally has no image of its own, so on every send the
        // one inspect names a tag Docker does not have: Docker prints the
        // base image's line and exits non-zero. If the real runner dropped
        // that output, every send would run the short check and then the
        // whole old path, more launches than before, and no scripted daemon
        // would show it: a fake never goes through the real runner.
        let args = BotComputerDockerCLI.imageStatesArguments(tags: ["a:1", "b:1"])
        let line = Data("[\"a:1\"]\tsha256:a\t{}\n".utf8)
        XCTAssertEqual(BotComputerDockerCLI.partialImageStates(args: args, status: 1, stdout: line), line)
        XCTAssertNil(
            BotComputerDockerCLI.partialImageStates(args: args, status: 1, stdout: Data()),
            "nothing printed: Docker could not tell, which is a failure"
        )
        for other in [["image", "inspect", "a:1"], ["inspect", "-f", "{{.Id}}", "a:1"], ["info"]] {
            XCTAssertNil(
                BotComputerDockerCLI.partialImageStates(args: other, status: 1, stdout: line),
                "any other failed command stays a failure: \(other)"
            )
        }
        // The real runner has no seam for a fake docker, so its use of the
        // rule is read from the source: the answer is returned before the
        // failure path forgets the docker executable.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/CoreModel/BotComputerDockerClient.swift"),
            encoding: .utf8
        )
        let runner = try XCTUnwrap(source.range(of: "public static func defaultRun("))
        let answered = try XCTUnwrap(source.range(of: "= partialImageStates(args: args, status: result.terminationStatus"))
        let forgotten = try XCTUnwrap(source.range(of: "invalidateIfMatches(executable)", range: runner.upperBound..<source.endIndex))
        XCTAssertLessThan(runner.upperBound, answered.lowerBound)
        XCTAssertLessThan(answered.lowerBound, forgotten.lowerBound)
    }

    func test_theImageInspectOfEverySend_givesUpAsSoonAsDockerInfoDoes() {
        // WHY: with the architecture remembered this inspect is the first
        // thing a send asks Docker. Under the 15 s limit of other commands a
        // daemon that hangs was named after 15 s + `info`'s 5 s, where it had
        // been 5 s. It is still asked before `info`, so the wait is 5 s + 5 s.
        XCTAssertEqual(
            BotComputerDockerCLI.timeoutForArguments(BotComputerDockerCLI.imageStatesArguments(tags: ["a:1", "b:1"])),
            BotComputerDockerCLI.timeoutForArguments(["info"])
        )
        XCTAssertEqual(BotComputerDockerCLI.timeoutForArguments(["image", "inspect", "a:1"]), 15)
    }

    func test_liveDockerAnswersForTheImageThatExists_whenTheOtherTagHasNone() throws {
        // WHY: a bot normally has no image of its own, so on every send the
        // one inspect names a tag Docker does not have and Docker exits
        // non-zero after printing the base image's line. If that output were
        // dropped, every send would pay the short check and then the old path:
        // slower than before. Only a real Docker shows what it prints.
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 to read two image tags from the real Docker (read-only)")
        }
        let listed = String(decoding: try BotComputerDockerCLI.defaultRun(
            ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"]
        ), as: UTF8.self)
        guard let existing = listed.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { !$0.contains("<none>") }) else {
            throw XCTSkip("this Docker has no tagged image to read")
        }
        let missing = "remotecode/computer:no-such-\(UUID().uuidString.lowercased())"

        let states = try BotComputerDockerCLI().imageStates(tags: [existing, missing])

        XCTAssertEqual(Array(states.keys), [existing])
        XCTAssertEqual(states[existing]?.id.hasPrefix("sha256:"), true)
    }

    // MARK: - Steps that run together (P1-13)

    private struct ResolverFixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let bot: BotDefinition
        let thread: AgentThread
        let vm: GatedGuestVM
        let leases: DistillGuestLeases
        let refreshes: Recorder<DistillAccountProvider?>
        let versionProbes: Recorder<String?>
        /// While true, the version read does not return (a distill binary that hangs).
        let versionProbeHeld: OSAllocatedUnfairLock<Bool>
        let binaries: Recorder<String>
        let resolver: BotGuestRunResolver
    }

    /// A desk conversation locked to a Docker-desktop bot's guest, with the
    /// VM start held at `vm.gate`.
    private func makeResolverFixture() async throws -> ResolverFixture {
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspaceDir = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "ws", cwd: workspaceDir.path)
        let bot = try ctx.botStore.create(
            name: "Vera", title: "", description: "", desktopKind: .dockerDesktop, workspaceID: workspace.id
        )
        // Provisioning creates the bot's guest home; the fake VM does not.
        try FileManager.default.createDirectory(
            at: BotComputerGuestSpec.guestHomeURL(appSupport: ctx.appSupportDirectory, botID: bot.id),
            withIntermediateDirectories: true
        )
        let hostHome = root.appendingPathComponent("host-distill", isDirectory: true)
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
        try """
            [models]
            default = "claude/claude-sonnet-4-5"

            [model.local]
            base_url = "http://127.0.0.1:8000/v1"
            api_key = "sk-local-secret"
            """.write(to: hostHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try #"{"access_token":"at-1","refresh_token":"rt-host-only","expires_at":4102444800000}"#
            .write(to: hostHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)

        let thread = try router.createAgentThread(
            workspace: nil, title: "Desk chat", provider: .distill,
            model: "claude/claude-sonnet-4-5", permissionMode: .supervised, reasoningEffort: .medium,
            routingConfiguration: nil, quiet: true
        )
        XCTAssertTrue(try ctx.threadRepo.setActor(
            id: thread.id, actor: .bot(bot.id), lockedAt: Date(), executionTarget: .vm
        ))
        XCTAssertTrue(try ctx.threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1))

        let vm = GatedGuestVM()
        let leases = DistillGuestLeases()
        let barrier = DistillGuestLaunchBarrier()
        await barrier.open()
        let refreshes = Recorder<DistillAccountProvider?>()
        let versionProbes = Recorder<String?>()
        let versionProbeHeld = OSAllocatedUnfairLock(initialState: false)
        let binaries = Recorder<String>()
        let gateway = BotGuestMCPGateway()
        gateways.append(gateway)
        let workspaces = [workspace.id: workspaceDir.path]
        let resolver = BotGuestRunResolver(BotGuestRunResolver.Dependencies(
            threadRepo: ctx.threadRepo,
            botStore: ctx.botStore,
            appSupport: ctx.appSupportDirectory,
            registry: BotVMRunRegistry(),
            leases: leases,
            barrier: barrier,
            gateway: gateway,
            vm: vm,
            binaryGuestPath: { hostBinary, arch in
                binaries.append("\(hostBinary ?? "none") \(arch)")
                return "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64"
            },
            refresh: { _, provider in refreshes.append(provider) },
            dockerExecutable: { "/usr/bin/true" },
            workspaces: { workspaces },
            hostBinary: { _ in hostDistill },
            probeHostVersion: { hostBinary in
                versionProbes.append(hostBinary)
                while versionProbeHeld.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 5_000_000) }
            },
            gitIdentity: { GitIdentity(name: "Ada", email: "ada@example.com") },
            processEnvironment: ["DISTILL_HOME": hostHome.path],
            heartbeatInterval: 0.05
        ))
        return ResolverFixture(
            ctx: ctx, router: router, bot: bot, thread: thread, vm: vm, leases: leases,
            refreshes: refreshes, versionProbes: versionProbes, versionProbeHeld: versionProbeHeld,
            binaries: binaries, resolver: resolver
        )
    }

    private func request(_ f: ResolverFixture, permit: AgentRunAcceptancePermit? = nil) -> AgentRunRequest {
        AgentRunRequest(
            threadId: f.thread.id, provider: .distill, model: "claude/claude-sonnet-4-5",
            cwd: root.appendingPathComponent("BotHome").path, prompt: "uname -a",
            environment: [BotSecretEnvironment.botIDEnvironmentKey: "bot", "PATH": "/usr/bin"],
            runAsUser: nil,
            acceptancePermit: permit
        )
    }

    /// The VM is still held at its gate and the Mac distill's version has
    /// already been asked for: the two run together.
    private func waitUntilBothAreInFlight(_ f: ResolverFixture, line: UInt = #line) async throws {
        try await waitUntil { f.vm.calls == 1 && f.versionProbes.values.count == 1 }
        XCTAssertEqual(
            f.versionProbes.values, [hostDistill],
            "the Mac distill's version is read while the VM comes up, not after it", line: line
        )
    }

    func test_theMacDistillVersionIsReadWhileTheVMComesUp_andTheGuestBinaryStillWaitsForTheVM() async throws {
        // WHY (P1-13): reading the Mac distill's version spawns a process and
        // needs nothing from the VM, yet it waited for the VM to be up. The
        // guest binary itself still needs the VM's architecture, and every
        // later step keeps its order.
        let f = try await makeResolverFixture()
        let stages = Recorder<DistillGuestStage>()
        let req = request(f)
        let run = Task { try await f.resolver.prepare(req) { stages.append($0) } }
        try await waitUntilBothAreInFlight(f)
        XCTAssertTrue(f.binaries.values.isEmpty, "the guest binary is picked by the VM's architecture")
        f.vm.gate.signal()

        let prepared = try await run.value
        let plan = try XCTUnwrap(prepared, "expected a guest launch plan")
        XCTAssertEqual(f.binaries.values, ["\(hostDistill) aarch64"])
        XCTAssertEqual(f.versionProbes.values.count, 1, "the resolver asks for the version once")
        XCTAssertEqual(stages.values, [.startingVM, .preparingAgent, .signingIn, .launching])
        XCTAssertEqual(f.refreshes.values, [.claude])
        await plan.finish(.completed).value
    }

    func test_stopWhileTheVMStartsAndTheVersionIsRead_stillLeavesNothingBehind() async throws {
        // WHY: two steps are now in flight when Stop arrives. The stopped send
        // must end as before: no launch plan, no sign-in renewal, no guest
        // binary resolved, and the bot's lease free for the next send.
        let f = try await makeResolverFixture()
        let permit = AgentRunAcceptancePermit()
        let req = request(f, permit: permit)
        let run = Task { try await f.resolver.prepare(req) { _ in } }
        try await waitUntilBothAreInFlight(f)
        permit.invalidate() // what the coordinator's Stop does to a pending start
        f.vm.gate.signal()
        do {
            let plan = try await run.value
            XCTFail("a stopped run must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(f.refreshes.values.isEmpty, "no sign-in renewal for a stopped run")
        XCTAssertTrue(f.binaries.values.isEmpty)
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld, "a stopped start must not keep the bot")
    }

    func test_aVMThatFailsWhileTheVersionIsRead_failsTheSendWithTheSameError() async throws {
        // WHY: running the two together must not change what a failed VM
        // start tells the user, nor leave the bot's lease held.
        let f = try await makeResolverFixture()
        f.vm.error = BotComputerGuestError.dockerUnavailable
        let run = Task { try await f.resolver.prepare(self.request(f)) { _ in } }
        try await waitUntilBothAreInFlight(f)
        f.vm.gate.signal()
        do {
            let plan = try await run.value
            XCTFail("a failed VM start must not get a launch plan")
            await plan?.finish(.cancelled).value
        } catch {
            XCTAssertEqual(
                error as? DistillGuestLaunchError,
                .unavailable(BotComputerGuestError.dockerUnavailable.description)
            )
        }
        XCTAssertTrue(f.refreshes.values.isEmpty)
        XCTAssertTrue(f.binaries.values.isEmpty)
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld, "a failed start must not keep the bot")
    }

    func test_aVMThatFails_isReportedAndFreesTheBot_withoutWaitingForAVersionReadThatHangs() async throws {
        // WHY: the version read is a process with a 5 s limit and nothing can
        // stop it early. A send whose VM start failed already has its answer:
        // the error and the bot's lease must not wait behind a distill binary
        // that hangs.
        let f = try await makeResolverFixture()
        f.versionProbeHeld.withLock { $0 = true }
        defer { f.versionProbeHeld.withLock { $0 = false } }
        f.vm.error = BotComputerGuestError.dockerUnavailable
        let req = request(f)
        let failures = Recorder<DistillGuestLaunchError?>()
        let run = Task {
            do {
                let plan = try await f.resolver.prepare(req) { _ in }
                await plan?.finish(.cancelled).value
            } catch {
                failures.append(error as? DistillGuestLaunchError)
            }
        }
        try await waitUntilBothAreInFlight(f)
        f.vm.gate.signal()

        try await waitUntil { !failures.values.isEmpty }

        XCTAssertTrue(f.versionProbeHeld.withLock { $0 }, "the version read is still held")
        XCTAssertEqual(failures.values, [.unavailable(BotComputerGuestError.dockerUnavailable.description)])
        let leaseHeld = await f.leases.isHeld(f.bot.id.value.uuidString.lowercased())
        XCTAssertFalse(leaseHeld, "a failed start must not keep the bot")
        f.versionProbeHeld.withLock { $0 = false }
        await run.value
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
