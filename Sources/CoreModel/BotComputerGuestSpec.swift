import Foundation
import CryptoKit

public enum BotComputerGuestSpec {
    /// Bump when start.sh / Dockerfile change. Missing label rebuilds the image.
    public static let recipeRevision = "8"
    /// Versioned so two app builds on different revisions sharing one Docker
    /// daemon (e.g. the debug sandbox and the installed app) never rebuild the
    /// same tag back and forth.
    public static let imageTag = "remotecode/computer:r\(recipeRevision)"
    public static let recipeLabelKey = "remotecode.recipe"
    /// SHA-256 of the recipe files an image was built from. The tag and the
    /// revision label alone do not identify the recipe: another build on the
    /// same daemon can leave a different image under this tag and revision.
    public static let recipeDigestLabelKey = "remotecode.recipe.sha256"
    public static let recipeFileNames = ["Dockerfile", "start.sh", "embed.html", "launch-browser.sh", "context-network.sh"]

    /// Digest over each recipe file's name and SHA-256 in `recipeFileNames`
    /// order; a missing file counts as absent, so adding one changes it too.
    public static func recipeDigest(context: URL) -> String {
        var manifest = ""
        for name in recipeFileNames {
            let file = (try? Data(contentsOf: context.appendingPathComponent(name)))
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            manifest += "\(name) \(file ?? "absent")\n"
        }
        return SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Bump when the container create options change. A container whose label
    /// differs is recreated, but only while the bot has no active run.
    public static let runtimeRevision = "8"
    public static let runtimeLabelKey = "remotecode.runtime"
    /// The bot (of the app database that created it) a container belongs to.
    public static let botIDLabelKey = "remotecode.botId"
    /// Read-only agent kit (guest Distill binary, scripts) shared by every bot.
    public static let agentKitMountPoint = "/opt/remotecode-agent"
    /// Lets the guest reach host loopback services by name on any Docker runtime.
    public static let hostGatewayAlias = "host.docker.internal:host-gateway"
    public static let guestUserHome = "/home/remotecode"
    /// Guest user that agent runs and `kill-agent` run as (`docker exec -u`).
    /// kill-agent refuses root: without CAP_SYS_PTRACE root cannot read the
    /// run tag in another user's /proc/<pid>/environ.
    public static let agentUser = "remotecode"
    /// `run-agent <runId> -- <argv>`: tags the run, records its pid, starts the
    /// lease reaper and execs argv (Resources/GuestAgentKit).
    public static let runAgentPath = "\(agentKitMountPoint)/bin/run-agent"
    /// `kill-agent <runId>|--all`: TERM then KILL; idempotent.
    public static let killAgentPath = "\(agentKitMountPoint)/bin/kill-agent"
    /// Vendored linux-use stdio MCP server (python3), native X11 tools only:
    /// the guest has no Chrome extension, so browser_* and jev_decide are removed.
    public static let linuxUseServerPath = "\(agentKitMountPoint)/linux-use/server.py"
    /// The Mac renews `<runId>.lease` here while it owns the run, by writing
    /// (re-creating) the file: the agent can delete it. run-agent's reaper ends
    /// a run whose lease has not changed for 45 s of its own polling.
    public static let agentLeaseDirectory = "\(guestUserHome)/.rc-runs"
    public static let screenPort = 6080
    public static let minimumShmBytes: Int = 256 * 1024 * 1024

    public static func containerName(botID: BotID) -> String {
        "remotecode-bot-\(botID.value.uuidString.lowercased())"
    }

    public static func guestHomeRoot(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("bot-guests", isDirectory: true)
    }

    public static func guestBotRootURL(appSupport: URL, botID: BotID) -> URL {
        guestHomeRoot(appSupport: appSupport)
            .appendingPathComponent(botID.value.uuidString.lowercased(), isDirectory: true)
    }

    public static func guestHomeURL(appSupport: URL, botID: BotID) -> URL {
        guestBotRootURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent("home", isDirectory: true)
    }

    /// Host side of `agentKitMountPoint`; bound read-only into every bot container.
    public static func guestToolsURL(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("guest-tools", isDirectory: true)
    }

    /// Kept out of every per-bot image build. The recipe lives in the guest home,
    /// which the guest can edit, and that home holds credentials and run state.
    public static let requiredDockerIgnorePatterns = [".distill", ".rc-*", ".browser-profiles"]
    /// Ignore files a builder may read instead of `.dockerignore`: BuildKit
    /// prefers `Dockerfile.dockerignore`, Podman/Buildah `.containerignore`.
    public static let alternateDockerIgnoreFileNames = ["Dockerfile.dockerignore", ".containerignore"]
    static let dockerIgnoreEnforcedHeader = "# RemoteCode: always excluded (rewritten before every build)"

    /// The bot's `.dockerignore` with the required patterns moved to the end.
    /// Docker applies the last matching line, so a `!` re-include written
    /// anywhere above cannot bring these paths back into the build context.
    public static func enforcedDockerIgnore(_ existing: String?) -> String {
        let required = Set(requiredDockerIgnorePatterns)
        let kept = (existing ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !required.contains(trimmed) && trimmed != dockerIgnoreEnforcedHeader
            }
        var lines = kept
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(dockerIgnoreEnforcedHeader)
        lines += requiredDockerIgnorePatterns
        return lines.joined(separator: "\n") + "\n"
    }

    public static func viewerTokenURL(appSupport: URL, botID: BotID) -> URL {
        guestBotRootURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent("viewer-token")
    }

    /// Per-bot Docker build context. Its editable Dockerfile lives at the guest-home root.
    public static func recipeURL(appSupport: URL, botID: BotID) -> URL {
        guestHomeURL(appSupport: appSupport, botID: botID)
    }

    /// Persisted workspace bind list for a bot's container.
    public static func workspacesURL(appSupport: URL, botID: BotID) -> URL {
        guestBotRootURL(appSupport: appSupport, botID: botID)
            .appendingPathComponent("workspaces.json")
    }

    public static let workspacesLabelKey = "remotecode.workspaces"

    /// SHA-256 hex of the sorted paths joined by newline. Empty list hashes the empty string.
    public static func workspacesLabel(_ workspaces: [String]) -> String {
        let joined = workspaces.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func assertWorkspaceMountPath(
        _ path: String,
        registeredWorkspaces: Set<String>? = nil,
        userHome: String = NSHomeDirectory()
    ) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"),
              path != "/",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw BotComputerGuestError.invalidWorkspacePath(path) }
        var home = userHome
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard path != home, !home.hasPrefix(path + "/") else {
            throw BotComputerGuestError.invalidWorkspacePath(path)
        }
        // Docker follows symlinks at bind time; a link resolving elsewhere would bypass the checks above.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard resolved == path, resolved != "/", resolved != resolvedHome,
              !resolvedHome.hasPrefix(resolved + "/")
        else { throw BotComputerGuestError.invalidWorkspacePath(path) }
        if let registeredWorkspaces, !registeredWorkspaces.contains(path) {
            throw BotComputerGuestError.invalidWorkspacePath(path)
        }
    }

    public static func botImageTag(botID: BotID) -> String {
        "remotecode/computer:bot-\(botID.value.uuidString.lowercased())"
    }

    public static func networkName(botID: BotID) -> String {
        "remotecode-bot-\(botID.value.uuidString.lowercased())"
    }

    public static func nextContainerName(botID: BotID) -> String {
        "\(containerName(botID: botID))-next"
    }

    public static func assertGuestHomePath(_ path: String, appSupport: URL, botID: BotID) throws {
        let allowed = guestHomeURL(appSupport: appSupport, botID: botID).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        if candidate.contains("..") {
            throw BotComputerGuestError.invalidHomePath
        }
        guard candidate == allowed || candidate.hasPrefix(allowed + "/") else {
            throw BotComputerGuestError.invalidHomePath
        }
    }

    public static func containerCreateOptions(
        botID: BotID,
        guestHome: String,
        appSupport: URL,
        viewerToken: String,
        image: String = imageTag,
        name: String? = nil,
        workspaces: [String] = [],
        registeredWorkspaces: Set<String>? = nil,
        userHome: String = NSHomeDirectory(),
        contextualNetworkPolicy: Bool = false
    ) throws -> BotComputerContainerCreateOptions {
        try assertGuestHomePath(guestHome, appSupport: appSupport, botID: botID)
        for workspace in workspaces {
            try assertWorkspaceMountPath(
                workspace,
                registeredWorkspaces: registeredWorkspaces,
                userHome: userHome
            )
        }
        guard viewerToken.range(of: #"^[a-zA-Z0-9-]{32,128}$"#, options: .regularExpression) != nil else {
            throw BotComputerGuestError.invalidScreenURL
        }
        return BotComputerContainerCreateOptions(
            name: name ?? containerName(botID: botID),
            image: image,
            labels: [
                "remotecode.managed": "1",
                botIDLabelKey: botID.value.uuidString.lowercased(),
                workspacesLabelKey: workspacesLabel(workspaces),
                runtimeLabelKey: runtimeRevision,
            ].merging(contextualNetworkPolicy ? ["remotecode.context.network": "private-egress-v1"] : [:]) { current, _ in current },
            environment: ["REMOTECODE_VIEWER_TOKEN": viewerToken]
                .merging(contextualNetworkPolicy ? ["REMOTECODE_CONTEXT_NETWORK_POLICY": "private-egress-v1"] : [:]) { current, _ in current },
            binds: ["\(guestHome):\(guestUserHome)"]
                + workspaces.map { "\($0):\($0)" }
                + ["\(guestToolsURL(appSupport: appSupport).path):\(agentKitMountPoint):ro"],
            hostIP: "127.0.0.1",
            hostPort: 0,
            containerPort: screenPort,
            shmSize: minimumShmBytes,
            network: networkName(botID: botID),
            initProcess: true,
            extraHosts: [hostGatewayAlias],
            capDrop: contextualNetworkPolicy ? ["ALL"] : [],
            capAdd: contextualNetworkPolicy ? ["NET_ADMIN"] : [],
            securityOptions: contextualNetworkPolicy ? ["no-new-privileges:true"] : [],
            tmpfs: contextualNetworkPolicy ? ["/run:rw,nosuid,nodev,noexec,mode=0755"] : []
        )
    }

    public static func terminalCommand() -> [String] {
        ["env", "DISPLAY=:1", "xterm"]
    }

    /// Playwright MCP inside the guest: headed on the Xvfb display so the user
    /// can watch and log in through the guest screen. Uses the image's chromium;
    /// Playwright must not download browsers in the guest.
    public static let playwrightGuestUserDataDir = "/home/remotecode/.browser-profiles/playwright"

    public static func playwrightMCPCommand(userDataDir: String = playwrightGuestUserDataDir) -> [String] {
        [
            "env", "DISPLAY=:1",
            "npx", "--yes", "@playwright/mcp@latest",
            "--executable-path", "/usr/bin/chromium",
            "--no-sandbox",
            "--user-data-dir", userDataDir,
        ]
    }

    /// Guest framebuffer size. start.sh starts `Xvfb :1 -screen 0 1280x800x24`
    /// (pinned by BotComputerGuestRecipeTests); act coordinates are bounded by it.
    public static let screenWidth = 1280
    public static let screenHeight = 800

    /// How long the bot's MCP child waits for an exec result, counted from the
    /// moment it queues the action. Everything the host does for that exec
    /// (queueing, provisioning, the command itself) must fit in this window.
    public static let execResultWaitSeconds: TimeInterval = 180
    /// Guest-side limit for bot_computer_exec. `timeout` stops the whole command
    /// group inside the guest (TERM, then KILL after the grace); killing only the
    /// host docker exec client would leave e.g. apt-get holding the dpkg lock.
    public static let execGuestDeadlineSeconds = 165
    public static let execGuestKillGraceSeconds = 5
    /// Host-side time for `docker exec` to return after the guest KILL.
    public static let execDockerSlackSeconds = 5
    /// Time for the host to write the result and the child to poll it.
    public static let execResultMarginSeconds = 2
    /// Below this, an exec is refused instead of being started with a budget
    /// too small to do anything useful.
    public static let execMinimumGuestSeconds = 5

    /// `docker build` deadline (base image and bot_computer_rebuild).
    public static let imageBuildDeadlineSeconds: TimeInterval = 600
    /// Create, start and screen-ready the rebuilt container, then swap it in.
    public static let rebuildReadyBudgetSeconds: TimeInterval = 180
    /// How long the bot's MCP child waits for a rebuild result: the build
    /// deadline plus the time to bring the rebuilt desktop up.
    public static var rebuildResultWaitSeconds: TimeInterval {
        imageBuildDeadlineSeconds + rebuildReadyBudgetSeconds
    }

    /// Host docker exec deadline for a guest limit: guest seconds + kill grace +
    /// docker teardown slack.
    public static func execHostDeadline(guestSeconds: Int) -> TimeInterval {
        TimeInterval(guestSeconds + execGuestKillGraceSeconds + execDockerSlackSeconds)
    }

    /// Host docker exec deadline for an exec that starts with its full budget.
    public static var execHostDeadlineSeconds: TimeInterval {
        execHostDeadline(guestSeconds: execGuestDeadlineSeconds)
    }

    /// Guest seconds an exec may run so its result still reaches a caller that
    /// stops waiting at `deadline`: what is left after provisioning and queueing,
    /// minus kill grace, docker slack and the result margin, capped at the guest
    /// deadline. nil when less than `execMinimumGuestSeconds` would be left.
    /// No deadline (a host-side caller) gets the full guest deadline.
    public static func execGuestBudgetSeconds(deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return execGuestDeadlineSeconds }
        let remaining = Int(deadline.timeIntervalSince(now).rounded(.down))
        let budget = remaining - execGuestKillGraceSeconds - execDockerSlackSeconds - execResultMarginSeconds
        guard budget >= execMinimumGuestSeconds else { return nil }
        return min(budget, execGuestDeadlineSeconds)
    }

    public static func execDeadlinePrefix(guestSeconds: Int) -> [String] {
        ["timeout", "-k", "\(execGuestKillGraceSeconds)", "\(guestSeconds)"]
    }

    public static var execDeadlinePrefix: [String] {
        execDeadlinePrefix(guestSeconds: execGuestDeadlineSeconds)
    }

    /// Guest argv for an agent shell command, bounded by `guestSeconds`.
    public static func deadlineExecCommand(
        _ command: String,
        guestSeconds: Int = execGuestDeadlineSeconds
    ) -> [String] {
        execDeadlinePrefix(guestSeconds: guestSeconds) + ["bash", "-lc", command]
    }

    /// The guest limit of an argv built by `deadlineExecCommand`, or nil when the
    /// argv is not a wrapped agent command.
    public static func execGuestSeconds(inExecArguments args: [String]) -> Int? {
        let lead = ["timeout", "-k", "\(execGuestKillGraceSeconds)"]
        guard args.count >= lead.count + 3 else { return nil }
        for start in 0...(args.count - lead.count - 3) {
            guard Array(args[start..<(start + lead.count)]) == lead,
                  let seconds = Int(args[start + lead.count]), seconds > 0,
                  args[start + lead.count + 1] == "bash",
                  args[start + lead.count + 2] == "-lc" else { continue }
            return seconds
        }
        return nil
    }

    public static func execUsesRoot(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("apt") || trimmed.hasPrefix("apt-get")
    }

    public static func assertExecCommand(_ command: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000, !trimmed.contains("\0") else {
            throw BotComputerGuestError.observeFailed
        }
        return trimmed
    }

    public static func screenURL(hostPort: Int, token: String) throws -> URL {
        guard hostPort > 0,
              token.range(of: #"^[a-zA-Z0-9-]{32,128}$"#, options: .regularExpression) != nil
        else { throw BotComputerGuestError.invalidScreenURL }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = hostPort
        components.path = "/vnc.html"
        components.queryItems = [
            URLQueryItem(name: "autoconnect", value: "1"),
            URLQueryItem(name: "resize", value: "scale"),
            URLQueryItem(name: "view_only", value: "0"),
            // noVNC plays bell.oga on every RFB Bell (xterm rings it constantly).
            // ui.js only plays when the `bell` config var is exactly "on".
            URLQueryItem(name: "bell", value: "off"),
            URLQueryItem(name: "path", value: "websockify?token=\(token)"),
        ]
        guard let url = components.url else { throw BotComputerGuestError.invalidScreenURL }
        return url
    }

    public static func validateScreenURL(_ url: URL) throws {
        guard url.host == "127.0.0.1" else { throw BotComputerGuestError.invalidScreenURL }
    }

    /// Desk/Studio viewer entry. Refuse any host that is not loopback.
    public static func viewerURL(_ url: URL) throws -> URL {
        try validateScreenURL(url)
        return url
    }
}

public struct BotComputerContainerCreateOptions: Equatable, Sendable {
    public var name: String
    public var image: String
    public var labels: [String: String]
    public var environment: [String: String]
    public var binds: [String]
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var shmSize: Int
    public var network: String?
    /// `--init`: an init process reaps orphans and forwards signals to start.sh.
    public var initProcess: Bool = false
    /// `--add-host` entries.
    public var extraHosts: [String] = []
    public var capDrop: [String] = []
    public var capAdd: [String] = []
    public var securityOptions: [String] = []
    public var tmpfs: [String] = []
}

public enum BotComputerGuestError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidHomePath
    case invalidScreenURL
    case dockerUnavailable
    case observeFailed
    case notReady
    case invalidWorkspacePath(String)

    public var description: String {
        switch self {
        case .invalidHomePath:
            return "Guest home path is not allowed."
        case .invalidScreenURL:
            return "Guest screen URL must stay on 127.0.0.1."
        case .dockerUnavailable:
            return "Docker is unavailable. Start Docker, then try again."
        case .observeFailed:
            return "Could not capture the Linux desktop."
        case .notReady:
            return "Docker desktop is not ready."
        case .invalidWorkspacePath(let path):
            return "Workspace path cannot be mounted into the guest: \(path)"
        }
    }

    public var errorDescription: String? { description }
}
