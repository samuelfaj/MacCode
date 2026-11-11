import Foundation

/// One RemoteCode-controlled layer in a Bot Brain compile.
public struct BotContextLayer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: Kind
    public var title: String
    public var text: String
    public var included: Bool
    public var reason: String

    public enum Kind: String, Codable, Sendable {
        case identity
        case desktop
        case permission
        case route
        case notifications
        case tools
        case description
        case soul
        case memory
        case skill
        case routine
        case browser
        case user
    }

    public init(
        id: String,
        kind: Kind,
        title: String,
        text: String,
        included: Bool,
        reason: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.included = included
        self.reason = reason
    }
}

/// What a model call compiled, including exclusions. Preview uses the same
/// compiler as send so Source/Effective cannot drift from the adapter payload.
public struct ContextAssemblyReceipt: Codable, Sendable, Equatable, Identifiable {
    public static let compilerVersion = "bots.brain.v2"

    public var id: UUID
    public var botID: BotID
    public var conversationID: BotConversationID?
    public var runID: AgentRunID?
    public var revisionID: BotRevisionID
    public var revisionNumber: Int
    public var revisionDigest: String
    public var provider: AgentProvider
    public var model: String
    public var permissionMode: AgentPermissionMode
    public var desktopKind: BotDesktopKind
    public var compilerVersion: String
    public var compiledPayload: String
    public var payloadDigest: String
    public var layers: [BotContextLayer]
    public var assembledAt: Date

    public init(
        id: UUID = UUID(),
        botID: BotID,
        conversationID: BotConversationID? = nil,
        runID: AgentRunID? = nil,
        revisionID: BotRevisionID,
        revisionNumber: Int,
        revisionDigest: String,
        provider: AgentProvider,
        model: String,
        permissionMode: AgentPermissionMode,
        desktopKind: BotDesktopKind,
        compilerVersion: String = ContextAssemblyReceipt.compilerVersion,
        compiledPayload: String,
        payloadDigest: String,
        layers: [BotContextLayer],
        assembledAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.conversationID = conversationID
        self.runID = runID
        self.revisionID = revisionID
        self.revisionNumber = revisionNumber
        self.revisionDigest = revisionDigest
        self.provider = provider
        self.model = model
        self.permissionMode = permissionMode
        self.desktopKind = desktopKind
        self.compilerVersion = compilerVersion
        self.compiledPayload = compiledPayload
        self.payloadDigest = payloadDigest
        self.layers = layers
        self.assembledAt = assembledAt
    }

    public var includedLayers: [BotContextLayer] { layers.filter(\.included) }
    public var excludedLayers: [BotContextLayer] { layers.filter { !$0.included } }
    public var memoryLayers: [BotContextLayer] { layers.filter { $0.kind == .memory } }
}

/// Studio already shows the workspace name. Compile name + cwd so
/// first-chat "which repo?" cannot invent a folder. Custom soul must
/// not hide advertised workspace. Blank name/cwd compile as isolation only.
public struct BotWorkspaceHonesty: Codable, Sendable, Equatable {
    public var name: String
    public var cwd: String

    public init(name: String, cwd: String = "") {
        self.name = name
        self.cwd = cwd
    }

    public var placeLabel: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return cwd }
        if cwd.isEmpty { return name }
        return "\(name) (\(cwd))"
    }
}

/// One This-bot skill file admitted into the compile payload.
public struct BotOwnedSkillText: Codable, Sendable, Equatable {
    public var slug: String
    public var body: String

    public init(slug: String, body: String) {
        self.slug = slug
        self.body = body
    }
}

/// One memory markdown file admitted into the compile payload.
public struct BotMemoryFileText: Codable, Sendable, Equatable {
    public var path: String
    public var body: String

    public init(path: String, body: String) {
        self.path = path
        self.body = body
    }
}

/// Compiles Source Brain layers into the Effective payload sent to a provider.
public enum BotBrainCompiler {
    /// Studio already shows Workspace. set_settings cannot persist a folder,
    /// so first-chat "use this Workspace" invented a write. Hermes workspace
    /// is host-pinned. Compile that so the model does not invent a persist.
    public static let workspaceHostAssignedHonesty = "Host-assigned. Not a self-config write."

    /// Studio Handle is create-only after first save. Compile already shows
    /// @handle next to Role, so first-chat "change your handle" invented a
    /// write. Hermes address is identity, not self-rewritable. Compile that
    /// so the model does not invent a persist.
    public static let handleCreateOnlyHonesty = "Handle is create-only. Not a self-config write."

    /// Studio already says Approval mode. Compile listed Permission, so
    /// first-chat "what's your Approval mode?" invented a hop. Desk always
    /// launches supervised. Leftover permission_mode writes reject, so
    /// first-chat "set Approval mode to full access" cannot invent a write.
    /// Hermes permission is host-pinned. Compile that so the model does
    /// not invent a persist. Dest Source title stays Permission.
    public static let approvalModeHostAssignedHonesty = "Host-assigned. Not a self-config write."

    /// Studio Security already says Approvals and Allow once / Deny stay
    /// off until P1b. Compile listed Approval mode only, so first-chat
    /// "Allow once" invented a grant. Hermes grants are host-owned.
    /// Compile that so the model does not invent a persist. Dest Source
    /// title stays Permission.
    public static let approvalsHonesty = "Approvals: Allow once / Deny stay off until P1b."

    /// Studio already says Test run. Compile listed Active routines only,
    /// so first-chat "test this routine" invented a hop or a schedule fire.
    /// Hermes test runs are live work, not a fake cron. Compile that so
    /// the model does the Instruction when asked and does not set Active.
    /// It rides on every turn, so it must stay conditional: an unconditional
    /// "do the Instruction now" turned a bare "oi" into the routine's PR
    /// merges. Dest Source title stays Routine. Schema does not grow a test tool.
    public static let testRunHonesty =
        "Test run: only when the User request below explicitly asks to test or run a routine, or the turn is a scheduled fire, do that routine's Instruction. A greeting or an unrelated request never starts a routine. Does not set Active. \(BotRoutineCopy.testRunHonestyCaption)"

    /// Follows the routine list. The list is a summary so the bot knows its
    /// routines without carrying (and obeying) every multi-KB Instruction on
    /// every turn; the full text stays one bot_get_settings call away.
    public static let routinesReferenceOnly =
        "Routines above are reference only, each with the first line of its Instruction; \(BotStandingInstructions.getSettingsTool) returns the full text. Do not act on them in this turn unless one fires on schedule or the User request below asks for it."

    /// Memory lives in Files. A leftover Memory / fact write on
    /// set_settings used to return an empty success, so first-chat
    /// invented a persist. Hermes memory writes stay on MEMORY.md
    /// and memory/YYYY-MM-DD.md. Dest Source title stays Memory.
    /// Schema does not grow a memory key.
    public static let memoryHonesty =
        "Memory: write MEMORY.md for durable facts or memory/YYYY-MM-DD.md for today. Edit those files to forget or correct. Same path as Files. Not a set_settings write."

    /// Forget is the same file write as Memory. Leftover Forget keys
    /// still reject on set_settings so first-chat cannot invent a persist.
    public static let forgetHonesty = memoryHonesty

    /// Correct is the same file write as Memory. Leftover Correct keys
    /// still reject on set_settings so first-chat cannot invent a persist.
    public static let correctHonesty = memoryHonesty

    /// Studio already says Skills. Compile already labels Skills.
    /// A leftover Skills / skill write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes skill
    /// writes stay on set_skill. Dest Source title stays Skills. Schema
    /// does not grow a skills key.
    public static let skillsHonesty =
        "Skills: write skills/<slug>/SKILL.md. Edit that file to add or correct. Same path as Files. Not a set_settings write."

    /// Remove is a file delete. Leftover Remove keys still reject on
    /// set_settings so first-chat cannot invent a persist.
    public static let removeHonesty =
        "Remove: delete skills/<slug>/SKILL.md. Same path as Files. Not a set_settings write."

    /// Studio already says Routines. Compile already labels Routines.
    /// A leftover Routines / routine write on set_settings used to return
    /// an empty success, so first-chat invented a persist. Hermes cron
    /// writes stay on save_routine / set_routine_enabled. Dest Source
    /// title stays Routines. Schema does not grow a routines key.
    public static let routinesHonesty =
        "Routines: call \(BotStandingInstructions.saveRoutineTool). Same path as Studio Save routine. Not a set_settings write."

    /// Studio already says Instruction. Compile already labels Instruction.
    /// A leftover instruction write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes cron
    /// writes stay on save_routine. Plural Instructions still persist
    /// soul. Dest Source title stays Routine. Schema does not grow an
    /// instruction key.
    public static let instructionHonesty =
        "Instruction: call \(BotStandingInstructions.saveRoutineTool). Same path as Studio Save routine. Not a set_settings write."

    /// Studio already says When. Compile already labels When. A leftover
    /// when write on set_settings used to return an empty success, so
    /// first-chat invented a persist. Hermes cron writes stay on
    /// save_routine. Dest Source title stays Routine. Schema does not
    /// grow a when key.
    public static let whenHonesty =
        "When: call \(BotStandingInstructions.saveRoutineTool). Same path as Studio Save routine. Not a set_settings write."

    /// Studio already says Active. Compile already labels Active. A leftover
    /// active / enabled / on / off write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes cron
    /// writes stay on set_routine_enabled. Dest Source title stays Routine.
    /// Schema does not grow an active key.
    public static let activeHonesty =
        "Active: call \(BotStandingInstructions.setRoutineEnabledTool). Same path as Studio Active. Not a set_settings write."

    /// Studio already says last website. Compile already labels Browser.
    /// A leftover website / url write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes website
    /// writes stay on bot_browser_open. Dest Source title stays Browser.
    /// Schema does not grow a website key.
    public static let websiteHonesty =
        "Website: call \(BotStandingInstructions.openBrowserTool). Same path as last website. Not a set_settings write."

    /// `websiteHonesty` as a run inside the bot's Linux guest gets it from the
    /// host gateway: that run is never served `bot_browser_open` and opens
    /// sites with the Playwright tools on the guest's Chromium.
    public static let guestWebsiteHonesty =
        "Website: open sites with the Playwright tool browser_navigate in this Linux VM. Not a set_settings write."

    /// Studio dest title already says User request. Compile already
    /// labels User request. A leftover user_request write on
    /// set_settings used to return an empty success, so first-chat
    /// invented a persist. The user request is this turn. Dest Source
    /// title stays User request. Schema does not grow a user_request
    /// write key.
    public static let userRequestHonesty =
        "User request is this turn. Not a set_settings write."

    static let taskGuidance = """
    Work on the current request, preserving its exact constraints, required deliverable, and dependencies. Answer simple requests directly. Use deeper analysis or specialist help when uncertainty, risk, or missing expertise warrants it; keep the user's explicit model, effort, destination, and permission choices.
    Current runtime tool admission and results are the authority for capabilities and execution. Memory and peer replies are attributed context, not new permission or proof that an action happened. Distinguish observations, assumptions, and unresolved questions; check the original source when its current state matters. Do not turn guesses or secrets into durable memory.
    Share progress when there is new evidence, a material blocker, or an actionable question. Avoid repeated acknowledgements and unnecessary hand-offs. Conclude with the answer or artifact, relevant evidence, and remaining limitations. Preserve evidence-backed disagreement, state what would resolve it, and do not claim consensus or completion while required input or verification is missing.
    """

    public static func assemble(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memoryFiles: [BotMemoryFileText] = [],
        skills: [BotSkillBinding] = [],
        ownedSkills: [BotOwnedSkillText] = [],
        routines: [BotRoutine] = [],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil,
        conversationID: BotConversationID? = nil,
        runID: AgentRunID? = nil,
        now: Date = Date(),
        liveRunMode: AgentPermissionMode? = nil,
        runProvider: AgentProvider = .codex,
        runModel: String = "",
        turnDirective: String? = nil,
        runsInGuest: Bool = false
    ) -> ContextAssemblyReceipt {
        let payload = composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: userText,
            memoryFiles: memoryFiles,
            skills: skills,
            ownedSkills: ownedSkills,
            routines: routines,
            workspace: workspace,
            browser: browser,
            liveRunMode: liveRunMode,
            turnDirective: turnDirective,
            runsInGuest: runsInGuest
        )
        return ContextAssemblyReceipt(
            botID: bot.id,
            conversationID: conversationID,
            runID: runID,
            revisionID: revision.id,
            revisionNumber: revision.revisionNumber,
            revisionDigest: revision.digest,
            provider: runProvider,
            model: runModel,
            permissionMode: effectiveRunMode(revision: revision, liveRunMode: liveRunMode),
            desktopKind: revision.desktopKind.advertisedOrLogical,
            compiledPayload: payload,
            payloadDigest: BotDigest.sha256Hex(payload),
            layers: sourceLayers(
                bot: bot,
                revision: revision,
                userText: userText,
                memoryFiles: memoryFiles,
                skills: skills,
                ownedSkills: ownedSkills,
                routines: routines,
                workspace: workspace,
                browser: browser,
                liveRunMode: liveRunMode,
                turnDirective: turnDirective,
                runsInGuest: runsInGuest
            ),
            assembledAt: now
        )
    }

    /// Exact adapter payload. Keep this body stable — Desk turns already persist it.
    public static func composeRunPrompt(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memoryFiles: [BotMemoryFileText] = [],
        skills: [BotSkillBinding] = [],
        ownedSkills: [BotOwnedSkillText] = [],
        routines: [BotRoutine] = [],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil,
        liveRunMode: AgentPermissionMode? = nil,
        turnDirective: String? = nil,
        runsInGuest: Bool = false
    ) -> String {
        var lines: [String] = []
        if let identity = identityLine(
            name: bot.name,
            handle: bot.handle,
            title: revision.title,
            avatarSymbol: bot.avatarSymbol
        ) {
            lines.append(identity)
        }
        // Studio already says Workspace. Compile that name so first-chat
        // "which Workspace?" cannot invent a hop. Host-assigned honesty
        // stays so first-chat cannot invent a set_settings write. Dest
        // Source title stays Working space.
        lines.append("Workspace: \(workingSpaceText(workspace))")
        // Studio already says Desktop. Compile that name so first-chat
        // "which Desktop?" cannot invent a hop. Isolation honesty lives
        // here, not on Workspace. Leftover VM kinds compile as logical.
        lines.append("Desktop: \(desktopText(for: revision, runsInGuest: runsInGuest))")
        // Studio already says Approval mode. Compile that name so first-chat
        // "what's your Approval mode?" cannot invent a hop. Studio Security
        // already says Approvals. Compile that name so first-chat "Allow
        // once" cannot invent a grant. Host-assigned honesty stays so
        // first-chat cannot invent a set_settings write. Dest Source
        // title stays Permission.
        lines.append("Approval mode: \(approvalModeText(for: effectiveRunMode(revision: revision, liveRunMode: liveRunMode)))")
        lines.append("Notifications: \(notificationsLine(enabled: bot.notificationsEnabled))")
        lines.append(BotStandingInstructions.admittedToolsText(for: revision.desktopKind, inGuest: runsInGuest))
        lines.append(taskGuidance)
        if bot.handle.lowercased() == TitioIdentity.handle {
            lines.append(TitioIdentity.orchestrationDirective)
        }
        if let browser = browserLine(browser) {
            lines.append(browser)
        }
        if let description = descriptionLine(revision.description) {
            lines.append(description)
        }
        // Before Instructions, so a custom soul that asks for another
        // style still has the last word.
        lines.append(contentsOf: BotStandingInstructions.replyStyleLines(for: bot))
        let soul = BotStandingInstructions.resolved(
            name: bot.name,
            title: revision.title,
            description: revision.description,
            soul: revision.soul
        )
        if !soul.isEmpty {
            // Studio already says Instructions. Compile that name so
            // first-chat "what are your Instructions?" cannot invent a hop.
            // Custom soul still wins the body.
            lines.append("Instructions:")
            lines.append(soul)
        }
        let liveMemory = memoryFiles.filter {
            !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !liveMemory.isEmpty {
            // Files already hold Memory. Compile that name so first-chat
            // "what's in Memory?" cannot invent a hop. Empty files stay out.
            lines.append("Memory:")
            lines.append(contentsOf: liveMemory.map(Self.memoryFileLine))
        }
        let owned = ownedSkills.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !owned.isEmpty {
            // Files already hold Skills. Compile an index so first-chat
            // "which Skills?" cannot invent a hop. Bodies load via bot_skill_view.
            lines.append("Skills:")
            lines.append(contentsOf: owned.map(Self.skillIndexLine))
        }
        let liveRoutines = routines.filter(\.activation.isEnabled)
            .sorted { $0.definition.name.localizedCaseInsensitiveCompare($1.definition.name) == .orderedAscending }
        if !liveRoutines.isEmpty {
            // Studio already says Routines. Compile that name so first-chat
            // "what are your Routines?" cannot invent a hop. Studio already
            // says Active. Keep Active on each live line so first-chat
            // "which are Active?" cannot invent a hop. Off stays out.
            lines.append("Routines (not while the app is closed):")
            lines.append(contentsOf: liveRoutines.map(Self.routineLine))
            lines.append(routinesReferenceOnly)
        }
        // Studio already says Test run. Compile that name so first-chat
        // "test this routine" cannot invent a hop or a schedule fire.
        // Only an explicit ask or a scheduled fire runs the Instruction;
        // stays even with no routines. Does not set Active. Dest Source
        // title stays Routine. Schema does not grow a test tool.
        lines.append(testRunHonesty)
        if let directive = turnDirective,
           !directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(directive)
        }
        lines.append("User request:")
        lines.append(userText)
        return lines.joined(separator: "\n\n")
    }

    static func workingSpaceText(_ workspace: BotWorkspaceHonesty? = nil) -> String {
        let place = workspace?.placeLabel ?? ""
        return place.isEmpty ? workspaceHostAssignedHonesty : "\(place). \(workspaceHostAssignedHonesty)"
    }

    /// Studio already says Approval mode. Compile supervised honesty plus
    /// Approvals Allow once / Deny stay off plus host-assigned so
    /// first-chat cannot invent a persist or a grant. Leftover
    /// full_access / auto_accept_edits still compile as supervised.
    static func effectiveRunMode(
        revision: BotRevision,
        liveRunMode: AgentPermissionMode?
    ) -> AgentPermissionMode {
        liveRunMode ?? BotPermission.advertisedOrSupervised(revision.permissionMode)
    }

    static func approvalModeText(for mode: AgentPermissionMode = .supervised) -> String {
        "\(honestyLabel(for: mode)) \(approvalsHonesty) \(approvalModeHostAssignedHonesty)"
    }

    static func honestyLabel(for mode: AgentPermissionMode) -> String {
        switch mode {
        case .supervised:
            return BotPermission.honestyLabel
        case .autoAcceptEdits:
            return "Auto-edit. Apply edits without asking."
        case .fullAccess:
            return "Full access. Run tools without asking."
        }
    }

    /// Studio already says Desktop. Compile display title + isolation so
    /// first-chat "which Desktop?" cannot invent a hop or a VM. Leftover
    /// Dedicated local VM / Managed remote Mac compile as Logical
    /// execution space. Not a self-config write — schema omits it.
    /// A Docker bot's thread says where its own agent runs (`runsInGuest`).
    static func desktopText(for revision: BotRevision, runsInGuest: Bool = false) -> String {
        let kind = revision.desktopKind.advertisedOrLogical
        guard kind == .dockerDesktop else { return "\(kind.displayTitle). \(kind.honestyLabel)" }
        let label = runsInGuest
            ? BotDesktopKind.dockerDesktopGuestRunHonestyLabel
            : BotDesktopKind.dockerDesktopMacRunHonestyLabel
        return "\(kind.displayTitle). \(label)"
    }

    /// Tools already persist last website. Compile it labeled so first-chat
    /// "what's open?" cannot invent a URL. Empty stays omitted. Custom soul
    /// must not hide the advertised last website. Cookies stay out.
    static func browserLine(_ target: BotBrowserTarget?) -> String? {
        let url = target?.url.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else { return nil }
        let title = target?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Browser: \(url)" : "Browser: \(title) (\(url))"
    }

    /// Studio already shows Description. Compile it labeled so first-chat
    /// "what's your description?" cannot treat unlabeled prose as soul.
    /// Empty stays omitted. Custom soul must not hide advertised about text.
    static func descriptionLine(_ description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "Description: \(trimmed)"
    }

    /// Studio already shows Notifications On/Off. Compile them so
    /// first-chat "will you notify me?" cannot invent alerts. Custom soul
    /// must not hide advertised notification power.
    static func notificationsLine(enabled: Bool) -> String {
        enabled
            ? "On. Alerts stay on this Mac; not an isolated Desktop."
            : "Off. This Mac will not alert the owner."
    }

    /// Desk already shows `@handle`. Compile it so first-chat "what's your handle?"
    /// cannot invent one. Custom soul must not hide advertised identity.
    /// Studio Handle is create-only. Compile that honesty so first-chat
    /// "change your handle" cannot invent a set_settings write. Empty
    /// handle omits the suffix.
    /// Studio already says Role. Compile that name so first-chat "what's your
    /// Role?" cannot invent a hop. Empty Role stays omitted. Custom soul
    /// must not hide the advertised job.
    /// Studio already picks Avatar. Compile the advertised chip so first-chat
    /// "what's my avatar?" cannot invent a symbol. Leftover SF paths stay out.
    static func identityLine(
        name: String,
        handle: String,
        title: String,
        avatarSymbol: String = ""
    ) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        var who = name
        if !handle.isEmpty {
            let tagged = "@\(handle)"
            who = who.isEmpty ? tagged : "\(who) (\(tagged))"
        }
        let role = roleLine(title)
        let avatar = avatarLine(avatarSymbol)
        var parts: [String] = []
        if !who.isEmpty {
            parts.append("You are \(who).")
        }
        if !handle.isEmpty { parts.append(handleCreateOnlyHonesty) }
        if let role {
            parts.append("\(role).")
        }
        if let avatar {
            parts.append("\(avatar).")
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " ")
    }

    /// Studio says Role. Compile that name, never an unlabeled job after an em-dash.
    static func roleLine(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "Role: \(trimmed)"
    }

    /// Studio says Star / Person. Compile that name, never the SF Symbol.
    static func avatarLine(_ symbol: String) -> String? {
        guard let parsed = BotAvatar.parse(symbol) else { return nil }
        let name = BotAvatar.advertisedName(for: parsed)
        guard !name.contains(".") else { return nil }
        return "Avatar: \(name)"
    }

    /// Desk forget/toggle tools require these keys. Snapshot already
    /// lowercases them. Compile them so first-chat cannot invent a UUID
    /// or a hidden get-settings hop. Custom soul must not hide them.
    static func mutateKey(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Files already hold Memory. Compile path + body so first-chat
    /// "what's in Memory?" cannot invent a hop. Empty files stay out.
    static func memoryFileLine(_ file: BotMemoryFileText) -> String {
        "### \(file.path)\n\(file.body)"
    }

    static func skillIndexLine(_ skill: BotOwnedSkillText) -> String {
        let description = skillDescription(skill.body)
        return "- \(skill.slug): \(description). Call \(BotStandingInstructions.viewSkillTool) to read skills/\(skill.slug)/SKILL.md."
    }

    static func skillDescription(_ body: String) -> String {
        // PERF: lazy split avoids materialising the whole body as [String]
        // when the description sits in frontmatter near the top; same result.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).lazy.map(String.init)
        var inFrontmatter = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                inFrontmatter.toggle()
                continue
            }
            if inFrontmatter, trimmed.lowercased().hasPrefix("description:") {
                let value = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            if trimmed.lowercased().hasPrefix("name:") { continue }
            return trimmed
        }
        return "Skill for this teammate."
    }

    /// Studio already says Instruction and When. Compile those names so
    /// first-chat "what's the Instruction?" cannot invent a hop. Empty
    /// When stays omitted. Studio already says Active. Live lines keep
    /// that name so first-chat "which are Active?" cannot invent a hop.
    /// Off dest rows omit Active. Instruction is its first line, capped:
    /// Studio Test run sends the full body as the User request, and
    /// bot_get_settings returns it.
    static func routineLine(_ routine: BotRoutine) -> String {
        let name = routine.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routineInstructionSummary(routine.definition.prompt)
        let note = routine.definition.scheduleNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = mutateKey(routine.definition.id.value)
        let active = routine.activation.isEnabled ? " Active." : ""
        if note.isEmpty {
            return "- \(name): Instruction: \(prompt).\(active) [\(key)]"
        }
        return "- \(name): Instruction: \(prompt). When: \(note).\(active) [\(key)]"
    }

    static let routineInstructionSummaryLimit = 160

    /// First non-empty line of a routine Instruction, cut to
    /// `routineInstructionSummaryLimit` characters with "…" when longer.
    static func routineInstructionSummary(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        let isCut = line.count > routineInstructionSummaryLimit || line.count < trimmed.count
        guard isCut else { return line }
        return String(line.prefix(routineInstructionSummaryLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func sourceLayers(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memoryFiles: [BotMemoryFileText],
        skills: [BotSkillBinding],
        ownedSkills: [BotOwnedSkillText] = [],
        routines: [BotRoutine],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil,
        liveRunMode: AgentPermissionMode? = nil,
        turnDirective: String? = nil,
        runsInGuest: Bool = false
    ) -> [BotContextLayer] {
        var layers: [BotContextLayer] = []
        if let identity = identityLine(
            name: bot.name,
            handle: bot.handle,
            title: revision.title,
            avatarSymbol: bot.avatarSymbol
        ) {
            layers.append(
                BotContextLayer(
                    id: "identity",
                    kind: .identity,
                    title: "Identity",
                    text: identity,
                    included: true,
                    reason: L("Name, handle, role, and avatar compile into the identity line.")
                )
            )
        } else {
            layers.append(
                BotContextLayer(
                    id: "identity",
                    kind: .identity,
                    title: "Identity",
                    text: "",
                    included: false,
                    reason: L("Name, handle, role, and avatar are empty.")
                )
            )
        }

        if let directive = turnDirective,
           !directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            layers.append(
                BotContextLayer(
                    id: "bot-delegation",
                    kind: .tools,
                    title: L("Bot delegation"),
                    text: directive,
                    included: true,
                    reason: L("Resolved Bot identities only. The provider interprets intent and authors every peer prompt.")
                )
            )
        }

        layers.append(
            BotContextLayer(
                id: "desktop",
                kind: .desktop,
                title: L("Working space"),
                text: workingSpaceText(workspace),
                included: true,
                reason: L("Advertised workspace. Host-assigned. Leftover folder writes stay off.")
            )
        )

        layers.append(
            BotContextLayer(
                id: "desktop-kind",
                kind: .desktop,
                title: "Desktop",
                text: desktopText(for: revision, runsInGuest: runsInGuest),
                included: true,
                reason: L("Advertised execution space. Leftover VM kinds compile as logical space.")
            )
        )

        layers.append(
            BotContextLayer(
                id: "permission",
                kind: .permission,
                title: "Permission",
                text: approvalModeText(for: effectiveRunMode(revision: revision, liveRunMode: liveRunMode)),
                included: true,
                reason: liveRunMode == nil
                    ? L("Advertised supervised route. Leftover full-access kinds compile as supervised.")
                    : L("Live composer chip. Host-assigned. Not a self-config write.")
            )
        )

        layers.append(
            BotContextLayer(
                id: "notifications",
                kind: .notifications,
                title: "Notifications",
                text: notificationsLine(enabled: bot.notificationsEnabled),
                included: true,
                reason: L("Advertised notification toggle. Studio already shows On or Off.")
            )
        )

        layers.append(
            BotContextLayer(
                id: "route",
                kind: .route,
                title: "Route",
                text: "",
                included: false,
                reason: L("Desk composer chooses the account per send. Studio no longer publishes a route.")
            )
        )

        layers.append(
            BotContextLayer(
                id: "tools",
                kind: .tools,
                title: L("Admitted tools"),
                text: BotStandingInstructions.admittedToolsText(for: revision.desktopKind, inGuest: runsInGuest),
                included: true,
                reason: L("Desk-admitted tools. Custom soul must not hide them.")
            )
        )
        layers.append(BotContextLayer(
            id: "task-guidance",
            kind: .tools,
            title: L("Task guidance"),
            text: taskGuidance,
            included: true,
            reason: L("Proportional reasoning and evidence. Runtime owns tool admission and permissions.")
        ))
        if bot.handle.lowercased() == TitioIdentity.handle {
            layers.append(BotContextLayer(
                id: "titio-control-center",
                kind: .tools,
                title: L("MacCode control center"),
                text: TitioIdentity.orchestrationDirective,
                included: true,
                reason: L("Current host capabilities for Titio chats and scheduled runs.")
            ))
        }

        if let browser = browserLine(browser) {
            layers.append(
                BotContextLayer(
                    id: "browser",
                    kind: .browser,
                    title: "Browser",
                    text: browser,
                    included: true,
                    reason: L("Advertised last website. Tools already persist it.")
                )
            )
        }

        if let description = descriptionLine(revision.description) {
            layers.append(
                BotContextLayer(
                    id: "description",
                    kind: .description,
                    title: "Description",
                    text: description,
                    included: true,
                    reason: L("Advertised about text. Studio already shows Description.")
                )
            )
        } else {
            layers.append(
                BotContextLayer(
                    id: "description",
                    kind: .description,
                    title: "Description",
                    text: "",
                    included: false,
                    reason: "No description."
                )
            )
        }

        let publishedSoul = revision.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        let soul = BotStandingInstructions.resolved(
            name: bot.name,
            title: revision.title,
            description: revision.description,
            soul: revision.soul
        )
        let soulReason = BotStandingInstructions.looksGenerated(publishedSoul)
            ? L("Built-in teammate default. Write standing instructions to replace it.")
            : L("Standing instructions are published with the revision.")
        layers.append(
            BotContextLayer(
                id: "soul",
                kind: .soul,
                title: L("Standing instructions"),
                text: soul,
                included: true,
                reason: soulReason
            )
        )

        for file in memoryFiles {
            let body = file.body.trimmingCharacters(in: .whitespacesAndNewlines)
            layers.append(
                BotContextLayer(
                    id: "memory-\(file.path)",
                    kind: .memory,
                    title: "Memory",
                    text: memoryFileLine(file),
                    included: !body.isEmpty,
                    reason: body.isEmpty ? L("Empty memory file. Not injected.") : L("Memory file.")
                )
            )
        }

        for binding in skills.sorted(by: { $0.skillID < $1.skillID }) {
            layers.append(
                BotContextLayer(
                    id: "skill-\(binding.skillID)",
                    kind: .skill,
                    title: "Skill",
                    text: binding.skillID,
                    included: false,
                    reason: L("Leftover catalog binding. Skills are files.")
                )
            )
        }

        for skill in ownedSkills {
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            layers.append(
                BotContextLayer(
                    id: "owned-skill-\(skill.slug)",
                    kind: .skill,
                    title: "Skill",
                    text: skillIndexLine(skill),
                    included: !body.isEmpty,
                    reason: body.isEmpty ? "Empty SKILL.md. Not injected." : "Skill index. Call bot_skill_view for the body."
                )
            )
        }

        for routine in routines.sorted(by: {
            $0.definition.name.localizedCaseInsensitiveCompare($1.definition.name) == .orderedAscending
        }) {
            layers.append(
                BotContextLayer(
                    id: "routine-\(routine.definition.id.value.uuidString.lowercased())",
                    kind: .routine,
                    title: "Routine",
                    text: routineLine(routine),
                    included: routine.activation.isEnabled,
                    reason: routine.activation.isEnabled
                        ? L("Active. Runs only while the app is open.")
                        : L("Off. Not injected.")
                )
            )
        }

        layers.append(
            BotContextLayer(
                id: "user",
                kind: .user,
                title: L("User request"),
                text: userText,
                included: true,
                reason: L("User request for this call.")
            )
        )
        return layers
    }
}
