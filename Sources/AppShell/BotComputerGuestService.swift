import Foundation
import CryptoKit
import os
import CoreModel
import Persistence

private let guestServiceLog = Logger(subsystem: "io.remotecode.agent", category: "bot.guest")

public struct BotComputerGuestReady: Equatable, Sendable {
    public var screenURL: URL
    public var pngHash: String
    public var pngMagic: String
    public var resumed: Bool
    public var containerID: String
    public var imageReference: String
    public var capturedPNG: Data
}

/// Secret-free projection used by paired clients. The noVNC loopback URL and
/// viewer bearer never leave the Mac; only a bounded PNG and exact runtime
/// identity cross the paired host channel.
public struct BotComputerGuestFrameEvidence: Equatable, Sendable {
    public var containerID: String
    public var imageReference: String
    public var viewerPath: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var png: Data
    public var pngHash: String
}

public enum BotComputerGuestServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case screenshotTooLarge(actualBytes: Int, maximumBytes: Int)
    case screenshotResultTooLarge(actualBytes: Int, maximumBytes: Int)
    case rebuildWhileRunActive(threadTitle: String)
    case contextualRuntimeUnavailable
    case contextualRuntimeCapacityReached(limit: Int)

    public var description: String {
        switch self {
        case .screenshotTooLarge(let actualBytes, let maximumBytes):
            return "Guest screenshot is too large: \(actualBytes) bytes (maximum \(maximumBytes))."
        case .screenshotResultTooLarge(let actualBytes, let maximumBytes):
            return "Guest screenshot result is too large: \(actualBytes) bytes (maximum \(maximumBytes))."
        case .rebuildWhileRunActive(let threadTitle):
            return "The Linux desktop was not rebuilt: \(threadTitle) is running on it. "
                + "Rebuild after that run finishes."
        case .contextualRuntimeUnavailable:
            return "Contextual guest runtime is unavailable."
        case .contextualRuntimeCapacityReached(let limit):
            return "At most \(limit) contextual desktops can run at once. Retry after one finishes."
        }
    }
}

public final class BotComputerGuestService: @unchecked Sendable {
    private static let sharedVMLabel = "remotecode.shared-vm"
    public static let pngMagicHex = "89504e47"
    public static let maxScreenshotBytes = 8 * 1_024 * 1_024
    public static let maxScreenshotBase64Bytes = ((maxScreenshotBytes + 2) / 3) * 4
    private static let viewerTokenLock = NSLock()
    private static let unprovenLock = NSLock()
    /// Containers started here whose desktop no screenshot has proven yet: a
    /// mount's replacement, a failed rebuild's rollback, a start whose
    /// screenshot failed. Static: a send's preflight and its guest prepare
    /// use different service instances.
    private static var unprovenContainers: Set<String> = []
    /// SHA-256 of every recipe file version earlier releases seeded into a bot's
    /// home. A per-bot copy still equal to one of them was never edited, so it is
    /// replaced with the current file; an edited copy stays the user's choice.
    static let previouslyShippedRecipeSHA256: [String: Set<String>] = [
        "Dockerfile": [
            "28da84d0e980c6862d74f1a55c4010e9e450ca718ea3931e19e02b5c7a781ef5",
            "f76708fdeadee4b8c2b970e6bcb0d1cf0143ed57331d14a14941406fbc438bb6", // revision 4
        ],
        "start.sh": [
            "3ee4664d5865f5316a2cf5b0bb8550dbe893d952c6ef71d4ae82f78d6451d840",
            "fc19d6b61e02c4ee713dde41886f4dfbae6d8631ce990dbd045f36eced478d8e", // unauthenticated viewer
            "7479a3389036155ed694292fcafeefb683a6dd79fbf8fa0a0e7e588f8fe69950", // revision 4
            "fa7a4feecd4b97cbd9d64ae537efade078e54281df250ba41ac5b5c5a7f5566f", // revision 5 before its lock comment
            "e91aa057e23e45af1c379bb8c0cf85548a293dbbfd028b9918fc7d7149e82a35", // revision 7, browser exit ended the container
        ],
        "launch-browser.sh": [
            "875c894932c673d7fdf66391eb38cb82002ea0ccc077b91108c486b9512419a3", // revision 4
        ],
        "embed.html": [
            "343261436d1a1b8d6f1f714cd9c517c3cf7032c296853bb720bc4b371f82d35c",
        ],
    ]

    private let appSupport: URL
    private let docker: any BotComputerDockerClienting
    private let recipeContext: URL?
    private let observeAttempts: Int
    private let observeDelay: TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    private let control: BotComputerControl
    private let screenshotLimiter: BotScreenshotRateLimiter
    private let notificationCenter: NotificationCenter
    private let vmRuns: BotVMRunRegistry
    private let gitRun: @Sendable ([String]) -> String?
    private let workspacesWriter: @Sendable (Data, URL) throws -> Void
    private let stateLock = NSLock()
    private var _lastReady: BotComputerGuestReady?
    private var _lastReason = "Guest is proving the screen…"
    public var lastReady: BotComputerGuestReady? { stateLock.withLock { _lastReady } }
    public var lastReason: String { stateLock.withLock { _lastReason } }
    public var recipeContextURL: URL? { recipeContext }

    public init(
        appSupport: URL,
        docker: any BotComputerDockerClienting,
        recipeContext: URL? = nil,
        observeAttempts: Int = 60,
        observeDelay: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        control: BotComputerControl = .shared,
        screenshotLimiter: BotScreenshotRateLimiter = .shared,
        notificationCenter: NotificationCenter = .default,
        vmRuns: BotVMRunRegistry = .shared,
        gitRun: @escaping @Sendable ([String]) -> String? = BotComputerGuestService.runGit,
        workspacesWriter: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.workspacesWriter = workspacesWriter
        self.vmRuns = vmRuns
        self.gitRun = gitRun
        self.control = control
        self.screenshotLimiter = screenshotLimiter
        self.notificationCenter = notificationCenter
        self.appSupport = appSupport
        self.docker = docker
        self.recipeContext = recipeContext
        self.observeAttempts = max(1, observeAttempts)
        self.observeDelay = max(0, observeDelay)
        self.sleep = sleep
    }

    public func proveReady() -> Bool {
        var probeName: String?
        var probeBotID: BotID?
        defer {
            if let probeName {
                try? docker.remove(name: probeName)
            }
            if let probeBotID {
                try? BotGuestHome.wipe(appSupport: appSupport, botID: probeBotID)
            }
        }
        do {
            _ = try docker.info()
            try? docker.removeMatching(namePrefix: "remotecode-probe-")
            try ensureCurrentImage()
            let name = "remotecode-probe-\(UUID().uuidString.lowercased())"
            probeName = name
            let botID = BotID()
            probeBotID = botID
            let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
            let viewerToken = try viewerToken(botID: botID)
            var options = try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: home.path,
                appSupport: appSupport,
                viewerToken: viewerToken,
                workspaces: loadWorkspaces(botID: botID)
            )
            options.name = name
            options.network = nil
            _ = try createContainer(options)
            try docker.start(name: name)
            let png = try waitForPNG(name: name)
            let hash = try BotComputerGuestObserve.validatePNG(png)
            let inspect = try docker.inspect(name: name)
            let url = try BotComputerGuestSpec.screenURL(hostPort: inspect.hostPort, token: viewerToken)
            try BotComputerGuestSpec.validateScreenURL(url)
            stateLock.withLock {
                _lastReady = BotComputerGuestReady(
                    screenURL: url,
                    pngHash: hash,
                    pngMagic: Self.pngMagic(png),
                    resumed: false,
                    containerID: name,
                    imageReference: inspect.imageID,
                    capturedPNG: png
                )
                _lastReason = ""
            }
            return true
        } catch {
            stateLock.withLock {
                _lastReady = nil
                if _lastReason == "Guest is proving the screen…" {
                    _lastReason = String(describing: error)
                }
            }
            return false
        }
    }

    /// `requestingThreadID` is the thread whose own run provisions the guest
    /// before starting in it; that run holding the bot does not keep an
    /// outdated container. nil treats any run holding the bot as another's.
    public func provision(botID: BotID, requestingThreadID: AgentThreadID? = nil) throws -> BotComputerGuestReady {
        try provision(botID: botID, keeping: [], requestingThreadID: requestingThreadID, contextualNetworkPolicy: false)
    }

    public func provision(
        contextBinding: BotContextBinding,
        workspace: Workspace?,
        registeredWorkspaces: Set<String>,
        requestingThreadID: AgentThreadID? = nil,
        virtualMachineID: UUID? = nil
    ) throws -> BotComputerGuestReady {
        guard contextBinding.state == .active, contextBinding.actions.contains(.send) else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        let identity = try BotContextRuntimeIdentity(binding: contextBinding, virtualMachineID: virtualMachineID)
        let desired: Set<String>
        switch contextBinding.context {
        case .general:
            guard workspace == nil else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
            desired = []
        case .workspace(let workspaceID):
            guard contextBinding.actions.contains(.files), let workspace,
                  workspace.id == workspaceID,
                  registeredWorkspaces.contains(workspace.cwd) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            try BotComputerGuestSpec.assertWorkspaceMountPath(workspace.cwd, registeredWorkspaces: registeredWorkspaces)
            let canonicalWorkspace = URL(fileURLWithPath: workspace.cwd).resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalSupport = appSupport.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalWorkspace != canonicalSupport,
                  !canonicalWorkspace.hasPrefix(canonicalSupport + "/"),
                  !canonicalSupport.hasPrefix(canonicalWorkspace + "/") else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            desired = [workspace.cwd]
        }
        let manifestURL = BotComputerGuestSpec.workspacesURL(appSupport: appSupport, botID: identity.storageBotID)
        let existing: Set<String>
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            existing = Set(paths)
        } else {
            existing = []
        }
        if virtualMachineID != nil, existing != desired {
            guard !heldByAnotherRun(botID: identity.storageBotID, requestingThreadID: requestingThreadID) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            try saveWorkspaces(Array(desired), botID: identity.storageBotID)
        } else if !existing.isSubset(of: desired) {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        if let path = desired.first {
            try ensureWorkspaceMounted(botID: identity.storageBotID, workspace: path, registered: registeredWorkspaces, requestingThreadID: requestingThreadID, contextualNetworkPolicy: true, sharedVirtualMachine: virtualMachineID != nil)
        }
        return try provision(botID: identity.storageBotID, keeping: desired, requestingThreadID: requestingThreadID, contextualNetworkPolicy: true, sharedVirtualMachine: virtualMachineID != nil)
    }

    private func provision(
        botID: BotID,
        keeping: Set<String>,
        requestingThreadID: AgentThreadID?,
        contextualNetworkPolicy: Bool = false,
        sharedVirtualMachine: Bool = false
    ) throws -> BotComputerGuestReady {
        let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        // A reused container sees the current kit through its bind too.
        try BotGuestAgentKit.materialize(appSupport: appSupport)
        try seedRecipe(botID: botID)
        try ensureCurrentImage()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let network = try availableNetwork(botID: botID)
        let image = try resolvedImage(botID: botID)
        let workspaces = prunedWorkspaces(botID: botID, keeping: keeping)
        var shared = sharedVirtualMachine
        if let existing = try? docker.inspect(name: name) {
            shared = shared || existing.labels[Self.sharedVMLabel] == "1"
            let policyLabel = existing.labels["remotecode.context.network"] == "private-egress-v1"
            guard contextualNetworkPolicy == policyLabel
                    || (shared && !heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID)) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            if contextualNetworkPolicy == policyLabel, networkMatches(existing, network: network),
               currentWorkspacesLabel(existing) == BotComputerGuestSpec.workspacesLabel(workspaces),
               heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID)
                || (imageMatches(existing, tag: image) && runtimeIsCurrent(existing)) {
                // Containers made before `--restart unless-stopped` keep Docker's default policy.
                do {
                    try docker.update(name: name, restartPolicy: "unless-stopped")
                } catch {
                    guestServiceLog.error("bot.guest.restart_policy_update_failed container=\(name, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
                if existing.running == false {
                    // Unproven until `readyState` has its screenshot.
                    Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(name) }
                    try docker.start(name: name)
                }
                return try readyState(name: name, botID: botID, resumed: true, contextualNetworkPolicy: contextualNetworkPolicy)
            }
            guard !heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID) else {
                throw BotStoreError.invalidInput("The VM is busy. Wait for the current conversation before changing its runtime.")
            }
            try? docker.remove(name: name)
        }
        let viewerToken = try viewerToken(botID: botID)
        var options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            viewerToken: viewerToken,
            image: image,
            workspaces: workspaces,
            contextualNetworkPolicy: contextualNetworkPolicy
        )
        if shared { options.labels[Self.sharedVMLabel] = "1" }
        options.network = network
        _ = try createContainer(options)
        // Unproven until `readyState` has its screenshot.
        Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(name) }
        try docker.start(name: name)
        return try readyState(name: name, botID: botID, resumed: false, contextualNetworkPolicy: contextualNetworkPolicy)
    }

    /// The bot's container when it is already running and nothing about it is
    /// out of date; nil when `ensureWorkspaceMounted` or `provision` has work
    /// to do. It applies their checks, but asks Docker twice (both images in
    /// one inspect, then the container) and takes no screenshot: a screenshot
    /// proves a desktop this call started, and this one was already up. A
    /// running container attached to the bot's network is what proves that
    /// network exists. An in-guest run asks this on every send.
    func runningCurrentContainer(
        botID: BotID,
        workspace: String?,
        registered: Set<String>,
        requestingThreadID: AgentThreadID?,
        contextualNetworkPolicy: Bool? = nil
    ) throws -> BotComputerContainerInspect? {
        let name = BotComputerGuestSpec.containerName(botID: botID)
        // Started with no screenshot of it yet: `provision` proves it.
        guard !Self.unprovenLock.withLock({ Self.unprovenContainers.contains(name) }) else { return nil }
        if let workspace {
            try BotComputerGuestSpec.assertWorkspaceMountPath(workspace, registeredWorkspaces: registered)
        }
        _ = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        // A reused container sees the current kit through its bind too.
        try BotGuestAgentKit.materialize(appSupport: appSupport)
        try seedRecipe(botID: botID)
        let baseTag = BotComputerGuestSpec.imageTag
        let botTag = BotComputerGuestSpec.botImageTag(botID: botID)
        let images = try docker.imageStates(tags: [baseTag, botTag])
        // `ensureCurrentImage` would build anything else.
        guard var image = images[baseTag] else { return nil }
        if let recipeContext {
            guard image.labels[BotComputerGuestSpec.recipeLabelKey] == BotComputerGuestSpec.recipeRevision,
                  image.labels[BotComputerGuestSpec.recipeDigestLabelKey]
                    == BotComputerGuestSpec.recipeDigest(context: recipeContext)
            else { return nil }
        }
        // `resolvedImage`: the bot's own image when it has a current one.
        if let own = images[botTag],
           own.labels[BotComputerGuestSpec.recipeLabelKey] == BotComputerGuestSpec.recipeRevision {
            image = own
        }
        // The test `ensureWorkspaceMounted` passes without touching the container.
        var mountedLabel: String?
        if let workspace {
            let stored = prunedWorkspaces(botID: botID, keeping: [workspace])
            guard stored.contains(workspace) else { return nil }
            mountedLabel = BotComputerGuestSpec.workspacesLabel(Array(Set(stored)))
        }
        // Read, not pruned: dropping a removed folder from the manifest is
        // `provision`'s, after `ensureWorkspaceMounted` has read it.
        let workspaces = loadWorkspaces(botID: botID).filter { FileManager.default.fileExists(atPath: $0) }
        guard let existing = try? docker.inspect(name: name), existing.running,
              existing.networkNames == [BotComputerGuestSpec.networkName(botID: botID)]
        else { return nil }
        if let contextualNetworkPolicy,
           contextualNetworkPolicy != (existing.labels["remotecode.context.network"] == "private-egress-v1") { return nil }
        let held = heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID)
        if let mountedLabel {
            guard existing.labels[BotComputerGuestSpec.workspacesLabelKey] == mountedLabel,
                  runtimeIsCurrent(existing) || held
            else { return nil }
        }
        guard currentWorkspacesLabel(existing) == BotComputerGuestSpec.workspacesLabel(workspaces),
              held || (!image.id.isEmpty && sameImage(existing.imageID, image.id) && runtimeIsCurrent(existing))
        else { return nil }
        return existing
    }

    /// Mounts `workspace` at the same path in the bot container. The old container
    /// stays as `<name>-backup` until the replacement is running.
    public func ensureWorkspaceMounted(
        botID: BotID,
        workspace: String,
        registered: Set<String>,
        requestingThreadID: AgentThreadID? = nil,
        contextualNetworkPolicy: Bool = false,
        sharedVirtualMachine: Bool = false
    ) throws {
        try BotComputerGuestSpec.assertWorkspaceMountPath(workspace, registeredWorkspaces: registered)
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        let existing = try? docker.inspect(name: canonical)
        if let existing {
            let policyLabel = existing.labels["remotecode.context.network"] == "private-egress-v1"
            if contextualNetworkPolicy != policyLabel {
                guard sharedVirtualMachine || existing.labels[Self.sharedVMLabel] == "1",
                      !heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID) else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
                _ = try provision(botID: botID, keeping: [workspace], requestingThreadID: requestingThreadID,
                                  contextualNetworkPolicy: contextualNetworkPolicy, sharedVirtualMachine: sharedVirtualMachine)
                try ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: registered,
                    requestingThreadID: requestingThreadID, contextualNetworkPolicy: contextualNetworkPolicy, sharedVirtualMachine: sharedVirtualMachine)
                return
            }
        }
        try BotGuestAgentKit.materialize(appSupport: appSupport)
        let stored = prunedWorkspaces(botID: botID, keeping: [workspace])
        let wanted = Array(Set(stored).union([workspace])).sorted()
        let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        guard existing != nil else {
            try saveWorkspaces(wanted, botID: botID)
            _ = try provision(botID: botID, keeping: [workspace], requestingThreadID: requestingThreadID, contextualNetworkPolicy: contextualNetworkPolicy)
            return
        }
        guard let existing else { return }
        if stored.contains(workspace),
           existing.labels[BotComputerGuestSpec.workspacesLabelKey] == BotComputerGuestSpec.workspacesLabel(wanted),
           runtimeIsCurrent(existing) || heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID) {
            return
        }
        guard !heldByAnotherRun(botID: botID, requestingThreadID: requestingThreadID) else {
            throw BotStoreError.invalidInput("The VM is busy. Wait for the current conversation before changing its workspace.")
        }
        let backup = canonical + "-backup"
        let network = try availableNetwork(botID: botID)
        var options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            viewerToken: try viewerToken(botID: botID),
            image: try resolvedImage(botID: botID),
            workspaces: wanted,
            registeredWorkspaces: registered.union(stored),
            contextualNetworkPolicy: contextualNetworkPolicy
        )
        if sharedVirtualMachine || existing.labels[Self.sharedVMLabel] == "1" {
            options.labels[Self.sharedVMLabel] = "1"
        }
        options.network = network
        if (try? docker.containerExists(name: backup)) == true {
            try? docker.remove(name: backup)
        }
        var renamed = false
        // Whatever ends up under this name was started here with no screenshot.
        Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(canonical) }
        do {
            try docker.stop(name: canonical)
            try docker.rename(from: canonical, to: backup)
            renamed = true
            _ = try createContainer(options)
            try docker.start(name: canonical)
        } catch {
            if renamed {
                try? docker.remove(name: canonical)
                try? docker.rename(from: backup, to: canonical)
            }
            try? docker.start(name: canonical)
            throw error
        }
        // Persist before dropping the backup: a failed save must leave the old VM and manifest intact.
        let manifestURL = BotComputerGuestSpec.workspacesURL(appSupport: appSupport, botID: botID)
        let previousManifest = try? Data(contentsOf: manifestURL)
        do {
            try saveWorkspaces(wanted, botID: botID)
        } catch {
            try? docker.remove(name: canonical)
            try? docker.rename(from: backup, to: canonical)
            try? docker.start(name: canonical)
            if let previousManifest {
                try? previousManifest.write(to: manifestURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: manifestURL)
            }
            throw error
        }
        try? docker.remove(name: backup)
    }

    private func runtimeIsCurrent(_ existing: BotComputerContainerInspect) -> Bool {
        existing.labels[BotComputerGuestSpec.runtimeLabelKey] == BotComputerGuestSpec.runtimeRevision
    }

    /// A container from an older image or older create options is only
    /// replaced while no other run holds the bot: recreating it would kill
    /// whatever that run has inside. The requesting thread's own run does not
    /// count, so an in-guest agent gets a current container before it starts.
    private func heldByAnotherRun(botID: BotID, requestingThreadID: AgentThreadID?) -> Bool {
        vmRuns.otherClaim(botID: botID, threadID: requestingThreadID) != nil
    }

    /// Every container binds the shared agent kit; its host directory must
    /// exist first or Docker would create it owned by the daemon. Materializing
    /// the kit creates it.
    private func createContainer(_ options: BotComputerContainerCreateOptions) throws -> String {
        try BotGuestAgentKit.materialize(appSupport: appSupport)
        return try docker.create(options: options)
    }

    private func currentWorkspacesLabel(_ existing: BotComputerContainerInspect) -> String {
        existing.labels[BotComputerGuestSpec.workspacesLabelKey] ?? BotComputerGuestSpec.workspacesLabel([])
    }

    /// Drops stored binds whose host path no longer exists, so a removed workspace cannot break container create.
    private func prunedWorkspaces(botID: BotID, keeping: Set<String>) -> [String] {
        let stored = loadWorkspaces(botID: botID)
        let live = stored.filter { keeping.contains($0) || FileManager.default.fileExists(atPath: $0) }
        if live.count != stored.count { try? saveWorkspaces(live, botID: botID) }
        return live
    }

    private func loadWorkspaces(botID: BotID) -> [String] {
        let url = BotComputerGuestSpec.workspacesURL(appSupport: appSupport, botID: botID)
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths.sorted()
    }

    private func saveWorkspaces(_ paths: [String], botID: BotID) throws {
        let url = BotComputerGuestSpec.workspacesURL(appSupport: appSupport, botID: botID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try workspacesWriter(JSONEncoder().encode(paths.sorted()), url)
    }

    /// Makes the bot's editable build recipe visible without starting Docker.
    public func prepareHome(botID: BotID) throws {
        _ = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        try seedRecipe(botID: botID)
    }

    public func stop(botID: BotID) throws {
        let claim = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Stopping VM", workspace: "", exclusive: true)
        if let holder = vmRuns.tryBegin(botID: botID, entry: claim) {
            throw BotStoreError.invalidInput("The VM is busy in \(holder.title). Stop that conversation first.")
        }
        defer {
            if let next = vmRuns.releaseAndNextWaiter(runID: claim.runID) {
                notificationCenter.post(name: .botVMRebuildReleased, object: nil,
                    userInfo: [BotHostNotificationKey.botID: next.botID, BotHostNotificationKey.threadID: next.threadID])
            }
        }
        try docker.stop(name: BotComputerGuestSpec.containerName(botID: botID))
    }

    public func stop(identity: BotContextRuntimeIdentity) throws {
        try stop(botID: identity.storageBotID)
    }

    public func inspectForContextRecovery(identity: BotContextRuntimeIdentity) throws -> BotComputerContainerInspect? {
        let name = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
        guard try docker.containerExists(name: name) else { return nil }
        let actual = try docker.inspect(name: name)
        try validateGatewayRuntime(actual, identity: identity)
        let expectedHome = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: identity.storageBotID)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard let source = actual.homeSource,
              URL(fileURLWithPath: source).resolvingSymlinksInPath().standardizedFileURL.path == expectedHome else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        return actual
    }

    public func stopForContextRecovery(identity: BotContextRuntimeIdentity) throws {
        guard let before = try inspectForContextRecovery(identity: identity), before.running else { return }
        try docker.stop(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID))
        guard let after = try inspectForContextRecovery(identity: identity), !after.running else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
    }

    public func installGatewayLease(
        identity: BotContextRuntimeIdentity,
        runID: AgentRunID,
        port: UInt16
    ) throws -> BotContextGatewayLease {
        guard port > 0 else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
        let name = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
        do {
            let inspect = try docker.inspect(name: name)
            try validateGatewayRuntime(inspect, identity: identity)
            guard inspect.running else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
            let hosts = try docker.exec(name: name, command: ["/bin/cat", "/etc/hosts"], user: "0", detach: false)
            guard let hostAddress = Self.gatewayIPv4(from: hosts) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            let run = runID.value.uuidString.lowercased()
            let output = try docker.exec(
                name: name,
                command: ["/usr/local/bin/rc-context-network", "--allow-gateway", run, hostAddress, String(port)],
                user: "0", detach: false
            )
            guard output == Data("context-gateway-lease-v1\n".utf8) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            return BotContextGatewayLease(identity: identity, runID: runID, hostAddress: hostAddress, port: port)
        } catch {
            stateLock.withLock { _lastReady = nil; _lastReason = "Context gateway lease failed; runtime cleanup unconfirmed." }
            Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(name) }
            throw error
        }
    }

    public func revokeGatewayLease(_ lease: BotContextGatewayLease) throws {
        let name = BotComputerGuestSpec.containerName(botID: lease.identity.storageBotID)
        do {
            let inspect = try docker.inspect(name: name)
            try validateGatewayRuntime(inspect, identity: lease.identity)
            guard inspect.running else { return }
            let output = try docker.exec(
                name: name,
                command: ["/usr/local/bin/rc-context-network", "--revoke-gateway", lease.runID.value.uuidString.lowercased(), lease.hostAddress, String(lease.port)],
                user: "0", detach: false
            )
            guard output == Data("context-gateway-revoked-v1\n".utf8) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
        } catch {
            stateLock.withLock { _lastReady = nil; _lastReason = "Context gateway cleanup unconfirmed." }
            Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(name) }
            throw error
        }
    }

    private func validateGatewayRuntime(_ inspect: BotComputerContainerInspect, identity: BotContextRuntimeIdentity) throws {
        guard inspect.labels[BotComputerGuestSpec.botIDLabelKey] == identity.storageBotID.value.uuidString.lowercased(),
              inspect.labels["remotecode.context.network"] == "private-egress-v1",
              inspect.labels[BotComputerGuestSpec.runtimeLabelKey] == BotComputerGuestSpec.runtimeRevision,
              inspect.networkNames == [BotComputerGuestSpec.networkName(botID: identity.storageBotID)] else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
    }

    static func gatewayIPv4(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count > 1, fields.dropFirst().contains("host.docker.internal") else { return nil }
            return String(fields[0])
        }
        guard matches.count == 1 else { return nil }
        let parts = matches[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { part -> UInt8? in
            guard let value = UInt8(part), String(value) == part else { return nil }
            return value
        }
        guard nums.count == 4, nums != [0, 0, 0, 0],
              (nums[0] == 10)
                || (nums[0] == 172 && (16...31).contains(nums[1]))
                || (nums[0] == 192 && nums[1] == 168)
                || (nums[0] == 100 && (64...127).contains(nums[1]))
                || (nums[0] == 169 && nums[1] == 254)
                || (nums[0] == 198 && (18...19).contains(nums[1]))
                || (nums[0] == 0 && nums[1...].contains(where: { $0 != 0 })) else { return nil }
        return matches[0]
    }

    public func wipe(identity: BotContextRuntimeIdentity) throws {
        let botID = identity.storageBotID
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let network = BotComputerGuestSpec.networkName(botID: botID)
        var containerRemovalError: Error?
        do { try docker.remove(name: name) } catch { containerRemovalError = error }
        var networkRemovalError: Error?
        do { try docker.removeNetwork(name: network) } catch { networkRemovalError = error }

        let containerExists: Bool
        do { containerExists = try docker.containerExists(name: name) }
        catch { throw containerRemovalError ?? networkRemovalError ?? error }
        let networkExists: Bool
        do { networkExists = try docker.networkExists(name: network) }
        catch { throw containerRemovalError ?? networkRemovalError ?? error }
        guard !containerExists, !networkExists else {
            throw containerRemovalError ?? networkRemovalError ?? BotComputerDockerError.provisioningFailed
        }
        try BotGuestHome.wipe(appSupport: appSupport, botID: botID)
    }

    /// What Docker says right now (one `docker inspect`): false when the
    /// container is stopped or gone, or Docker does not answer.
    public func isContainerRunning(botID: BotID) -> Bool {
        (try? docker.inspect(name: BotComputerGuestSpec.containerName(botID: botID)))?.running == true
    }

    /// An admitted run already prepared its mounts and network policy.
    /// Tool calls must use that runtime without replacing its container.
    private func ensureToolRuntime(botID: BotID) throws {
        if vmRuns.active(botID: botID) != nil, isContainerRunning(botID: botID) { return }
        _ = try provision(botID: botID)
    }

    /// `deadline` is when the MCP caller stops waiting; the guest limit is sized
    /// from what is left of it after provisioning (see `execGuestBudgetSeconds`).
    public func exec(botID: BotID, command: String, deadline: Date? = nil) throws -> Data {
        let trimmed = try BotComputerGuestSpec.assertExecCommand(command)
        try ensureToolRuntime(botID: botID)
        let guestSeconds = try Self.execGuestSeconds(deadline: deadline)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let user = BotComputerGuestSpec.execUsesRoot(trimmed) ? "0" : nil
        let data = try docker.exec(
            name: name,
            command: BotComputerGuestSpec.deadlineExecCommand(trimmed, guestSeconds: guestSeconds),
            user: user,
            detach: false
        )
        if data.count <= 32_768 { return data }
        return data.prefix(32_768)
    }

    /// Runs inside a mounted workspace as the host user's uid:gid ("0" for root commands).
    /// Only git identity is injected; no host credentials reach the guest.
    public func exec(
        botID: BotID,
        command: String,
        workspace: String,
        user: String,
        gitIdentity: GitIdentity?,
        deadline: Date? = nil
    ) throws -> Data {
        let trimmed = try BotComputerGuestSpec.assertExecCommand(command)
        try BotComputerGuestSpec.assertWorkspaceMountPath(workspace)
        try ensureToolRuntime(botID: botID)
        let guestSeconds = try Self.execGuestSeconds(deadline: deadline)
        var environment: [String: String] = [:]
        if let gitIdentity {
            environment = [
                "GIT_AUTHOR_NAME": gitIdentity.name,
                "GIT_AUTHOR_EMAIL": gitIdentity.email,
                "GIT_COMMITTER_NAME": gitIdentity.name,
                "GIT_COMMITTER_EMAIL": gitIdentity.email,
            ]
        }
        let data = try docker.exec(
            name: BotComputerGuestSpec.containerName(botID: botID),
            command: BotComputerGuestSpec.deadlineExecCommand(trimmed, guestSeconds: guestSeconds),
            user: BotComputerGuestSpec.execUsesRoot(trimmed) ? "0" : user,
            detach: false,
            workdir: workspace,
            environment: environment
        )
        if data.count <= 32_768 { return data }
        return data.prefix(32_768)
    }

    public static let execBudgetExhaustedMessage =
        "The command was not run: starting the Linux desktop used up the time this "
        + "bot_computer_exec call had. Call bot_computer_exec again."

    private static func execGuestSeconds(deadline: Date?) throws -> Int {
        guard let seconds = BotComputerGuestSpec.execGuestBudgetSeconds(deadline: deadline, now: Date()) else {
            throw BotComputerError.invalid(execBudgetExhaustedMessage)
        }
        return seconds
    }

    /// `run` receives git arguments and returns trimmed stdout, or nil on failure.
    public static func gitIdentity(
        run: ([String]) -> String? = BotComputerGuestService.runGit
    ) -> GitIdentity? {
        guard let name = run(["config", "--get", "user.name"]), !name.isEmpty,
              let email = run(["config", "--get", "user.email"]), !email.isEmpty
        else { return nil }
        return GitIdentity(name: name, email: email)
    }

    public static func runGit(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func openTerminal(botID: BotID) throws {
        try ensureToolRuntime(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        _ = try docker.exec(
            name: name,
            command: BotComputerGuestSpec.terminalCommand(),
            user: nil,
            detach: true
        )
    }

    static let rebuildClaimTitle = "Linux desktop rebuild"

    /// Refused while another thread's run is on the VM: the rebuild replaces
    /// the container that run is using. `requestingThreadID` is the thread whose
    /// own agent asked for the rebuild (nil for the user's Rebuild button).
    /// The rebuild holds the VM exclusively until it is done, so a send made
    /// during the build queues instead of starting on the old container.
    public func rebuild(botID: BotID, requestingThreadID: AgentThreadID? = nil) throws -> BotComputerGuestReady {
        let container = BotComputerGuestSpec.containerName(botID: botID)
        var sharedVirtualMachine = false
        var contextualNetworkPolicy = false
        if try docker.containerExists(name: container) {
            let existing = try docker.inspect(name: container)
            sharedVirtualMachine = existing.labels[Self.sharedVMLabel] == "1"
            contextualNetworkPolicy = existing.labels["remotecode.context.network"] == "private-egress-v1"
            guard !contextualNetworkPolicy || sharedVirtualMachine else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
        }
        let claim = BotVMRunRegistry.Entry(
            threadID: requestingThreadID ?? AgentThreadID(), runID: AgentRunID(), title: Self.rebuildClaimTitle,
            workspace: "", exclusive: true
        )
        // Exclusive until the new container runs: other threads' runs neither
        // run in the container this stops nor start during the build. The
        // requesting thread's own run keeps going.
        if let holder = vmRuns.tryBegin(botID: botID, entry: claim) {
            throw BotComputerGuestServiceError.rebuildWhileRunActive(threadTitle: holder.title)
        }
        defer {
            if let next = vmRuns.releaseAndNextWaiter(runID: claim.runID) {
                notificationCenter.post(
                    name: .botVMRebuildReleased, object: nil,
                    userInfo: [BotHostNotificationKey.botID: next.botID, BotHostNotificationKey.threadID: next.threadID]
                )
            }
        }
        try seedRecipe(botID: botID)
        let recipe = BotComputerGuestSpec.recipeURL(appSupport: appSupport, botID: botID)
        let tag = BotComputerGuestSpec.botImageTag(botID: botID)
        try docker.build(context: recipe, tag: tag)
        let home = try BotGuestHome.ensure(appSupport: appSupport, botID: botID)
        let network = try availableNetwork(botID: botID)
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        let next = BotComputerGuestSpec.nextContainerName(botID: botID)
        try? docker.remove(name: next)
        let viewerToken = try viewerToken(botID: botID)
        var options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home.path,
            appSupport: appSupport,
            viewerToken: viewerToken,
            image: tag,
            name: next,
            workspaces: loadWorkspaces(botID: botID),
            contextualNetworkPolicy: contextualNetworkPolicy
        )
        if sharedVirtualMachine { options.labels[Self.sharedVMLabel] = "1" }
        options.network = network
        _ = try createContainer(options)
        let canonicalWasRunning = (try? docker.inspect(name: canonical))?.running == true
        var stoppedCanonical = false
        do {
            // Both containers bind this home. Stop the old one before the new
            // one starts, so two Chromiums never write one profile (cookies,
            // logins) at the same time.
            if canonicalWasRunning {
                try docker.stop(name: canonical)
                stoppedCanonical = true
            }
            try docker.start(name: next)
            _ = try readyState(name: next, botID: botID, resumed: false)
            try? docker.remove(name: canonical)
            try docker.rename(from: next, to: canonical)
            let renamed = try readyState(name: canonical, botID: botID, resumed: false)
            stateLock.withLock { _lastReady = renamed }
            return renamed
        } catch {
            try? docker.remove(name: next)
            if stoppedCanonical, (try? docker.containerExists(name: canonical)) == true {
                // Started again with no screenshot. Marked here, not before
                // the stop: a screenshot taken until then clears the mark.
                Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(canonical) }
                try? docker.start(name: canonical)
            }
            throw error
        }
    }

    public func apply(_ action: BotComputerPendingAction, resourceID: BotID? = nil) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: action.botID) else {
            throw BotComputerError.invalid("Invalid bot id.")
        }
        let botID = BotID(uuid)
        let resource = resourceID ?? botID
        let callerThread = action.threadID.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        if let holder = vmRuns.blocker(botID: resource, threadID: callerThread),
           resource != botID || callerThread != nil {
            throw BotComputerError.invalid("The VM is busy in \(holder.title)")
        }
        // Refused, never queued: nothing below runs while the user drives.
        if action.kind == BotComputerCatalog.act || action.kind == BotComputerCatalog.exec,
           control.isControlledByUser(botID, resourceID: resource) {
            return ["refusal": ManualActionRequest.refusalPhrase]
        }
        let threadID = action.threadID.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        switch action.kind {
        case BotComputerCatalog.observe:
            let shot = try observe(botID: resource)
            let base64 = try Self.boundedBase64(shot.png)
            return [
                "png_magic": shot.magic,
                "png_hash": shot.hash,
                "png_base64": base64,
                "host": "127.0.0.1",
                "image": BotComputerGuestSpec.imageTag,
            ]
        case BotComputerCatalog.act:
            try act(botID: resource, steps: action.steps)
            return ["ok": true, "steps": action.steps.count]
        case BotComputerCatalog.exec:
            let output: Data
            if let run = vmRuns.claim(botID: resource, threadID: callerThread)
                ?? (callerThread == nil ? vmRuns.active(botID: resource) : nil) {
                output = try exec(
                    botID: resource,
                    command: action.command,
                    workspace: run.workspace,
                    user: "\(getuid()):\(getgid())",
                    gitIdentity: Self.gitIdentity(run: gitRun),
                    deadline: action.deadline
                )
            } else {
                output = try exec(botID: resource, command: action.command, deadline: action.deadline)
            }
            return [
                "ok": true,
                "output": String(data: output, encoding: .utf8) ?? "",
            ]
        case BotComputerCatalog.rebuild:
            let ready = try rebuild(botID: resource, requestingThreadID: threadID)
            return [
                "ok": true,
                "host": ready.screenURL.host ?? "127.0.0.1",
                "image": BotComputerGuestSpec.botImageTag(botID: resource),
            ]
        case BotComputerCatalog.requestUserAction:
            let kind = ManualActionKind(rawValue: action.subkind) ?? .other
            // Sharing a Mac file needs consent, not a working guest display.
            let png = kind == .file ? nil : try observe(botID: resource).png
            let base64 = try png.map(Self.boundedBase64)
            let id = ManualActionHost.request(
                control: control,
                botID: botID,
                threadID: threadID,
                kind: kind,
                reason: action.reason,
                screenshotPNG: png,
                center: notificationCenter
            )
            var reply: [String: Any] = [
                "request_id": id.uuidString.lowercased(),
                "message": ManualActionRequest.pauseReply,
            ]
            if let base64 { reply["png_base64"] = base64 }
            return reply
        case BotComputerCatalog.postScreenshot:
            let kind = BotScreenshotKind(rawValue: action.subkind) ?? .normal
            if let blocked = screenshotLimiter.acquire(botID: botID, kind: kind).message {
                throw BotComputerError.invalid(blocked)
            }
            let shot = try observe(botID: resource)
            let jpeg = try BotScreenshotEncoder.jpeg(fromPNG: shot.png)
            var userInfo: [String: Any] = [
                BotHostNotificationKey.botID: botID,
                BotHostNotificationKey.jpeg: jpeg.data,
                BotHostNotificationKey.reason: action.reason,
                BotHostNotificationKey.kind: kind.rawValue,
            ]
            if let threadID { userInfo[BotHostNotificationKey.threadID] = threadID }
            notificationCenter.post(name: .botScreenshotPosted, object: nil, userInfo: userInfo)
            return ["ok": true, "width": jpeg.width, "height": jpeg.height]
        case BotComputerCatalog.requestMacExecution:
            var userInfo: [String: Any] = [
                BotHostNotificationKey.botID: botID,
                BotHostNotificationKey.reason: action.reason,
            ]
            if let threadID { userInfo[BotHostNotificationKey.threadID] = threadID }
            notificationCenter.post(name: .botMacExecutionRequested, object: nil, userInfo: userInfo)
            return ["ok": true, "message": Self.macExecutionReply]
        default:
            throw BotComputerError.invalid("unknown tool: \(action.kind)")
        }
    }

    public static let macExecutionReply = "Request sent to the user; wait for approval. End your turn."

    private static func boundedBase64(_ png: Data) throws -> String {
        let base64 = png.base64EncodedString()
        guard base64.utf8.count <= maxScreenshotBase64Bytes else {
            throw BotComputerGuestServiceError.screenshotResultTooLarge(
                actualBytes: base64.utf8.count,
                maximumBytes: maxScreenshotBase64Bytes
            )
        }
        return base64
    }

    private func waitForPNG(name: String, attempts: Int? = nil) throws -> Data {
        var lastError: Error = BotComputerGuestError.observeFailed
        let observeAttempts = attempts.map { max(1, $0) } ?? self.observeAttempts
        for attempt in 0..<observeAttempts {
            do {
                let png = try docker.exec(
                    name: name,
                    command: ["env", "DISPLAY=:1", "import", "-window", "root", "png:-"],
                    user: nil,
                    detach: false
                )
                guard png.count <= Self.maxScreenshotBytes else {
                    throw BotComputerGuestServiceError.screenshotTooLarge(
                        actualBytes: png.count,
                        maximumBytes: Self.maxScreenshotBytes
                    )
                }
                _ = try BotComputerGuestObserve.validatePNG(png)
                return png
            } catch let error as BotComputerGuestServiceError {
                // An oversized frame is deterministic for the current guest
                // state. Retrying it 60 times only repeats the allocation and
                // keeps the Docker worker busy without changing the outcome.
                if case .screenshotTooLarge = error {
                    throw error
                }
                lastError = error
            } catch let error as BotComputerDockerError {
                // The bounded subprocess reader has already terminated this
                // exact-output command; repeating it only recreates the same
                // oversized frame and burns the retry window.
                if error == .outputTooLarge {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
                if attempt + 1 < observeAttempts {
                    sleep(observeDelay)
                }
            }
        }
        throw lastError
    }

    private func readyState(name: String, botID: BotID, resumed: Bool, contextualNetworkPolicy: Bool = false) throws -> BotComputerGuestReady {
        if contextualNetworkPolicy {
            Self.unprovenLock.withLock { _ = Self.unprovenContainers.insert(name) }
            do {
                let initial = try docker.inspect(name: name)
                guard initial.labels["remotecode.context.network"] == "private-egress-v1" else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
                let output = try docker.exec(name: name, command: ["/usr/local/bin/rc-context-network"], user: "0", detach: false, workdir: nil, environment: [:])
                guard output == Data("context-network-policy-v1\n".utf8) else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
            } catch {
                stateLock.withLock { _lastReady = nil; _lastReason = "Context network policy bootstrap failed; runtime cleanup unconfirmed." }
                do { try docker.stop(name: name) } catch {
                    stateLock.withLock { _lastReason = "Context network policy bootstrap failed; runtime cleanup unconfirmed: stop failed: \(error)." }
                }
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
        }
        let png = try waitForPNG(name: name)
        Self.unprovenLock.withLock { _ = Self.unprovenContainers.remove(name) }
        let hash = try BotComputerGuestObserve.validatePNG(png)
        let inspect = try docker.inspect(name: name)
        let url = try BotComputerGuestSpec.screenURL(
            hostPort: inspect.hostPort,
            token: try viewerToken(botID: botID)
        )
        try BotComputerGuestSpec.validateScreenURL(url)
        let ready = BotComputerGuestReady(
            screenURL: url,
            pngHash: hash,
            pngMagic: Self.pngMagic(png),
            resumed: resumed,
            containerID: name,
            imageReference: inspect.imageID,
            capturedPNG: png
        )
        stateLock.withLock {
            _lastReady = ready
            _lastReason = ""
        }
        return ready
    }

    private func resolvedImage(botID: BotID) throws -> String {
        let tag = BotComputerGuestSpec.botImageTag(botID: botID)
        if try docker.imageExists(tag: tag),
           try docker.imageLabel(tag: tag, key: BotComputerGuestSpec.recipeLabelKey)
            == BotComputerGuestSpec.recipeRevision {
            return tag
        }
        return BotComputerGuestSpec.imageTag
    }

    private func availableNetwork(botID: BotID) throws -> String {
        let name = BotComputerGuestSpec.networkName(botID: botID)
        try docker.ensureNetwork(name: name)
        return name
    }

    /// Bots now provision on their own lanes; keep one base-image check/build
    /// at a time instead of racing `docker build` of the same tag.
    private static let baseImageLock = NSLock()

    private func ensureCurrentImage() throws {
        Self.baseImageLock.lock()
        defer { Self.baseImageLock.unlock() }
        let tag = BotComputerGuestSpec.imageTag
        let exists = try docker.imageExists(tag: tag)
        guard let recipeContext else {
            if exists { return }
            stateLock.withLock { _lastReason = "Docker image missing" }
            throw BotComputerGuestError.dockerUnavailable
        }
        // The tag and revision can belong to an image another build left on
        // this daemon; only the recipe digest says it was built from this one.
        if exists,
           (try? docker.imageLabel(tag: tag, key: BotComputerGuestSpec.recipeLabelKey)) == BotComputerGuestSpec.recipeRevision,
           (try? docker.imageLabel(tag: tag, key: BotComputerGuestSpec.recipeDigestLabelKey))
            == BotComputerGuestSpec.recipeDigest(context: recipeContext) {
            return
        }
        try docker.build(context: recipeContext, tag: tag)
    }

    private func imageMatches(_ existing: BotComputerContainerInspect, tag: String) -> Bool {
        let want = (try? docker.imageID(tag: tag)) ?? ""
        if want.isEmpty { return true }
        return sameImage(existing.imageID, want)
    }

    private func sameImage(_ containerImage: String, _ want: String) -> Bool {
        containerImage == want
            || containerImage.hasSuffix(want)
            || want.hasSuffix(containerImage)
    }

    private func networkMatches(_ existing: BotComputerContainerInspect, network: String) -> Bool {
        existing.networkNames.isEmpty || existing.networkNames == [network]
    }

    private func seedRecipe(botID: BotID) throws {
        let dest = BotComputerGuestSpec.recipeURL(appSupport: appSupport, botID: botID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let names = BotComputerGuestSpec.recipeFileNames
        let legacy = dest.appendingPathComponent("computer", isDirectory: true)
        for name in names {
            let target = dest.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                if let recipeContext {
                    try refreshUneditedRecipeFileIfNeeded(
                        name: name,
                        at: target,
                        from: recipeContext.appendingPathComponent(name)
                    )
                }
                continue
            }
            let legacySource = legacy.appendingPathComponent(name)
            if fileManager.fileExists(atPath: legacySource.path) {
                try fileManager.moveItem(at: legacySource, to: target)
                continue
            }
            guard let recipeContext else { continue }
            let source = recipeContext.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: target)
            }
        }
        if fileManager.fileExists(atPath: legacy.path),
           (try fileManager.contentsOfDirectory(atPath: legacy.path)).isEmpty {
            try fileManager.removeItem(at: legacy)
        }
        try enforceDockerIgnore(in: dest)
    }

    /// The build context is the guest-writable home; re-assert the exclusions
    /// every time the recipe is prepared, so a guest edit cannot pull
    /// credentials or run state into a rebuilt image. That covers every ignore
    /// file a builder may prefer over `.dockerignore`, when one exists. A home
    /// without a Dockerfile is not a build context and is left untouched.
    private func enforceDockerIgnore(in recipe: URL) throws {
        guard FileManager.default.fileExists(atPath: recipe.appendingPathComponent("Dockerfile").path) else { return }
        try enforceIgnoreFile(recipe.appendingPathComponent(".dockerignore"), createIfMissing: true)
        for name in BotComputerGuestSpec.alternateDockerIgnoreFileNames {
            try enforceIgnoreFile(recipe.appendingPathComponent(name), createIfMissing: false)
        }
    }

    private func enforceIgnoreFile(_ url: URL, createIfMissing: Bool) throws {
        // Attributes of the item itself: a symlink is not followed.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == nil, !createIfMissing { return }
        // Only a regular file is read. Following a guest-planted symlink would
        // copy whatever host file it names into the guest-readable home.
        let existing = type == .typeRegular
            ? (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
            : nil
        let enforced = BotComputerGuestSpec.enforcedDockerIgnore(existing)
        guard type != .typeRegular || enforced != existing else { return }
        // .atomic replaces a guest-planted symlink instead of writing through it.
        try Data(enforced.utf8).write(to: url, options: .atomic)
    }

    private func viewerToken(botID: BotID) throws -> String {
        Self.viewerTokenLock.lock()
        defer { Self.viewerTokenLock.unlock() }
        let tokenURL = BotComputerGuestSpec.viewerTokenURL(appSupport: appSupport, botID: botID)
        if let data = try? Data(contentsOf: tokenURL, options: .mappedIfSafe), let raw = String(data: data, encoding: .utf8) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.range(of: #"^[a-zA-Z0-9-]{32,128}$"#, options: .regularExpression) != nil {
                return value
            }
        }
        let value = UUID().uuidString.lowercased()
        try Data((value + "\n").utf8).write(to: tokenURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return value
    }

    // PERF: nibble table avoids String(format:) per byte; same lowercase hex.
    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)
    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(digest.underestimatedCount * 2)
        for b in digest {
            out.append(hexAlphabet[Int(b >> 4)])
            out.append(hexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private func refreshUneditedRecipeFileIfNeeded(name: String, at target: URL, from source: URL) throws {
        guard let shipped = Self.previouslyShippedRecipeSHA256[name] else { return }
        let existing = try Data(contentsOf: target, options: .mappedIfSafe)
        let digest = Self.hexString(SHA256.hash(data: existing))
        guard shipped.contains(digest),
              FileManager.default.fileExists(atPath: source.path)
        else { return }
        try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
    }

    public static func pngMagic(_ data: Data) -> String {
        Self.hexString(data.prefix(4))
    }

    public func observe(botID: BotID) throws -> (png: Data, hash: String, magic: String) {
        try ensureToolRuntime(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let png = try waitForPNG(name: name)
        let hash = try BotComputerGuestObserve.validatePNG(png)
        return (png, hash, Self.pngMagic(png))
    }

    /// `attempts` caps the screenshot retries (default: the service's observe
    /// budget). A paired viewer's observe passes 1 so a failing guest answers now.
    public func remoteFrame(
        botID: BotID,
        ready: BotComputerGuestReady? = nil,
        attempts: Int? = nil
    ) throws -> BotComputerGuestFrameEvidence {
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let inspect = try docker.inspect(name: name)
        guard inspect.running else { throw BotComputerGuestError.notReady }
        let png: Data
        if let ready {
            guard ready.containerID == name,
                  ready.imageReference == inspect.imageID,
                  ready.pngHash == (try BotComputerGuestObserve.validatePNG(ready.capturedPNG)),
                  ready.pngMagic == Self.pngMagic(ready.capturedPNG) else {
                throw BotComputerGuestError.notReady
            }
            png = ready.capturedPNG
        } else {
            png = try waitForPNG(name: name, attempts: attempts)
        }
        let hash = try BotComputerGuestObserve.validatePNG(png)
        let dimensions = try Self.pngDimensions(png)
        return BotComputerGuestFrameEvidence(
            containerID: name,
            imageReference: inspect.imageID,
            viewerPath: "/vnc.html",
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            png: png,
            pngHash: hash
        )
    }

    public func act(botID: BotID, steps: [BotComputerActStep]) throws {
        try BotComputerGuestObserve.assertActStepCount(steps.count)
        try ensureToolRuntime(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        for step in steps {
            _ = try docker.exec(
                name: name,
                command: try step.execCommand(),
                user: nil,
                detach: false
            )
        }
    }

    public func teardown(botID: BotID) {
        try? removeGuestRuntime(botID: botID)
        try? BotGuestHome.wipe(appSupport: appSupport, botID: botID)
    }

    public func removeGuestRuntime(botID: BotID) throws {
        let name = BotComputerGuestSpec.containerName(botID: botID)
        var removalError: Error?
        do {
            try docker.remove(name: name)
        } catch {
            removalError = error
        }
        do {
            try docker.removeNetwork(name: BotComputerGuestSpec.networkName(botID: botID))
        } catch {
            // Network cleanup is independent from executable container state.
            // Verify the canonical runtime below before deciding the receipt.
        }
        let runtimeExists: Bool
        do {
            runtimeExists = try docker.containerExists(name: name)
        } catch {
            throw removalError ?? error
        }
        guard runtimeExists == false else {
            throw removalError ?? BotComputerDockerError.provisioningFailed
        }
    }

    private static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24,
              data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              data[12..<16] == Data("IHDR".utf8) else {
            throw BotComputerGuestError.observeFailed
        }
        func value(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = value(at: 16)
        let height = value(at: 20)
        guard width > 0, height > 0, width <= 8_192, height <= 8_192 else {
            throw BotComputerGuestError.observeFailed
        }
        return (width, height)
    }
}
