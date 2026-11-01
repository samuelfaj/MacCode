import XCTest
@testable import CoreModel

final class BotBrainCompilerTests: XCTestCase {
    func test_taskGuidanceIsRecordedWithoutRewritingRequestOrDirective() {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id, revisionNumber: 1, name: bot.name, title: bot.title,
            description: "", soul: "Be brief.", permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace, digest: "revision"
        )
        let request = "  Compare the evidence.\nKeep `limit = 17`; do not publish.  "
        let directive = "  Required source: files/result.md\n\nDo not repeat the action.  "
        let receipt = BotBrainCompiler.assemble(
            bot: bot, revision: revision, userText: request, turnDirective: directive
        )

        XCTAssertTrue(receipt.compiledPayload.hasSuffix("User request:\n\n" + request))
        XCTAssertEqual(receipt.layers.first { $0.kind == .user }?.text, request)
        XCTAssertEqual(receipt.layers.first { $0.id == "bot-delegation" }?.text, directive)
        XCTAssertTrue(receipt.compiledPayload.contains(directive))
        let guidance = receipt.layers.first { $0.id == "task-guidance" }
        XCTAssertEqual(guidance?.text, BotBrainCompiler.taskGuidance)
        XCTAssertEqual(guidance?.included, true)
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.taskGuidance))
        XCTAssertTrue(receipt.compiledPayload.contains("Answer simple requests directly."))
        XCTAssertTrue(receipt.compiledPayload.contains("not new permission or proof that an action happened"))
    }

    func test_effectivePayloadMatchesComposeAndExcludesForgottenMemory() {
        // WHY: Brain Inspector Effective must be the exact adapter payload.
        // A second compiler path would show Source/Effective that the model never saw.
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: "Looks around"
        )
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let live = BotMemoryFileText(path: "MEMORY.md", body: "Prefers dark mode")
        let empty = BotMemoryFileText(path: "memory/2026-08-17.md", body: "   ")
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)

        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [live, empty],
            skills: [enabled, disabled]
        )
        let composed = BotBrainCompiler.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [live, empty],
            skills: [enabled, disabled]
        )

        XCTAssertEqual(receipt.compiledPayload, composed)
        XCTAssertEqual(receipt.payloadDigest, BotDigest.sha256Hex(composed))
        XCTAssertEqual(receipt.compilerVersion, ContextAssemblyReceipt.compilerVersion)
        XCTAssertTrue(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(receipt.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains("Role: Scout"))
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(receipt.compiledPayload.contains("Description: Looks around"))
        XCTAssertFalse(receipt.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertFalse(receipt.compiledPayload.contains("memory/2026-08-17.md"))
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("memory/2026-08-17.md") })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Prefers dark mode") })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "off-skill" })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .user })?.text, "Summarize overnight")
        XCTAssertEqual(receipt.desktopKind, .logicalExecutionSpace)
    }

    func test_leftoverDedicatedLocalVMReceiptResolvesToLogicalSpace() {
        // WHY: A stored leftover kind must not appear as the live desktop on
        // Brain receipts after Dedicated local VM was removed from Studio.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let leftover = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .dedicatedLocalVM,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: leftover, userText: "Hi")
        XCTAssertEqual(receipt.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(receipt.desktopKind.honestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Guest is not running"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Working space" })?.text,
            BotBrainCompiler.workspaceHostAssignedHonesty
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Desktop" })?.text,
            "\(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
        )
    }

    func test_desktopKindsAdmitDifferentTools_becauseTheOwnerPicksTheBrowser() {
        // WHY: this-Mac bots keep native host computer-use and the owner's Google Chrome
        // — never bot_browser_*. Bot browser is the bot's own Playwright.
        // Docker browses via Playwright inside its guest, never this Mac.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        func revision(_ kind: BotDesktopKind) -> BotRevision {
            BotRevision(
                botID: bot.id,
                revisionNumber: 1,
                name: "Piper",
                title: "Scout",
                description: "",
                soul: "",
                provider: .claude,
                providerInstanceID: "claude",
                model: "opus",
                reasoningEffort: .medium,
                compatibleRouteSet: ["default"],
                permissionMode: .supervised,
                desktopKind: kind,
                digest: "x"
            )
        }
        let host = BotBrainCompiler.assemble(bot: bot, revision: revision(.logicalExecutionSpace), userText: "Hi")
        XCTAssertTrue(host.compiledPayload.contains(BotStandingInstructions.computerUseObservationTool))
        XCTAssertFalse(
            host.compiledPayload.contains(BotStandingInstructions.openBrowserTool),
            "an owner's-Chrome bot must not be taught refused bot_browser_* tools"
        )

        let owned = BotBrainCompiler.assemble(bot: bot, revision: revision(.botOwnedBrowser), userText: "Hi")
        XCTAssertFalse(owned.compiledPayload.contains(BotStandingInstructions.computerUseObservationTool))
        XCTAssertTrue(owned.compiledPayload.contains(BotStandingInstructions.openBrowserTool))
        XCTAssertTrue(owned.compiledPayload.contains(BotDesktopKind.botOwnedBrowser.displayTitle))

        let docker = BotBrainCompiler.assemble(bot: bot, revision: revision(.dockerDesktop), userText: "Hi")
        XCTAssertFalse(docker.compiledPayload.contains(BotStandingInstructions.generatedNativeHostComputerLine))
        XCTAssertTrue(
            docker.compiledPayload.contains(BotStandingInstructions.generatedBrowserLine),
            "a docker bot browses via bot_browser_* backed by Playwright inside its guest"
        )
        XCTAssertTrue(docker.compiledPayload.contains(BotStandingInstructions.computerObserveTool))
        XCTAssertTrue(docker.compiledPayload.contains(BotDesktopKind.dockerDesktop.displayTitle))

        // WHY (plan A S11): a Docker bot's thread whose agent runs inside its
        // guest has other tools (own shell, linux-use, Playwright, gateway bot
        // tools) and another place than a Mac thread of the same bot. The
        // payload and the Source layers come from one compiler and must agree.
        let guest = BotBrainCompiler.assemble(
            bot: bot, revision: revision(.dockerDesktop), userText: "Hi", runsInGuest: true
        )
        let guestDesktop = "\(BotDesktopKind.dockerDesktop.displayTitle). \(BotDesktopKind.dockerDesktopGuestRunHonestyLabel)"
        let guestTools = BotStandingInstructions.admittedToolsText(for: .dockerDesktop, inGuest: true)
        XCTAssertTrue(guest.compiledPayload.contains("Desktop: \(guestDesktop)"))
        XCTAssertTrue(guest.compiledPayload.contains(guestTools))
        XCTAssertFalse(guest.compiledPayload.contains(BotStandingInstructions.generatedGuestComputerLine))
        XCTAssertFalse(guest.compiledPayload.contains(BotStandingInstructions.generatedBrowserLine))
        XCTAssertEqual(guest.layers.first { $0.id == "desktop-kind" }?.text, guestDesktop)
        XCTAssertEqual(guest.layers.first { $0.id == "tools" }?.text, guestTools)
        XCTAssertTrue(
            docker.compiledPayload.contains("Desktop: \(BotDesktopKind.dockerDesktop.displayTitle). \(BotDesktopKind.dockerDesktopMacRunHonestyLabel)"),
            "a Mac run of a Docker bot keeps saying its agent stays on this Mac"
        )
        XCTAssertEqual(
            BotBrainCompiler.assemble(bot: bot, revision: revision(.logicalExecutionSpace), userText: "Hi", runsInGuest: true).compiledPayload,
            host.compiledPayload,
            "only a Docker bot has a guest to run in"
        )
    }

    func test_workingSpaceCompilesForCustomSoul_becauseIsolationHonestyIsNotAnEscapeHatch() {
        // WHY: Studio already shows desktop honesty to the owner. The model
        // never saw it, so "are you isolated?" invented a VM. A written soul
        // must not hide the advertised execution space — Hermes agents know
        // their sandbox even when SOUL.md is custom.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Are you isolated?")
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.title == "Desktop" })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Desktop" })?.reason,
            "Advertised execution space. Leftover VM kinds compile as logical space."
        )
    }

    func test_workspaceHonestyCompilesForCustomSoul_becauseStudioWorkspaceIsNotAnEscapeHatch() {
        // WHY: Studio already shows Workspace. The model never saw name or
        // cwd, so first-chat "which repo?" invented a folder. A written soul
        // must not hide the advertised workspace — Hermes agents know their
        // cwd even when SOUL.md is custom.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let workspace = BotWorkspaceHonesty(name: "macos-app", cwd: "/tmp/macos-app")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which repo is this?",
            workspace: workspace
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.title == "Working space" })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Working space" })?.text,
            "macos-app (/tmp/macos-app). \(BotBrainCompiler.workspaceHostAssignedHonesty)"
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Desktop" })?.text,
            "\(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("macos-app"),
            "workspace honesty is a compiler layer, not starter soul"
        )
    }

    func test_emptyWorkspaceDoesNotInventAFolder_becauseCompileMustNotAdvertiseNone() {
        // WHY: Studio shows "None" when no workspace is bound. Compile must
        // not invent a folder name or emit "None" as if it were a repo.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let blank = BotWorkspaceHonesty(name: "  ", cwd: "  ")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which repo is this?",
            workspace: blank
        )
        XCTAssertEqual(blank.placeLabel, "")
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Workspace: None"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Working space" })?.text,
            BotBrainCompiler.workspaceHostAssignedHonesty
        )
    }

    func test_workspaceHonestyNamesHostAssigned_becauseSetSettingsCannotPersistAFolder() {
        // WHY: Studio already shows Workspace. Compile listed it next to
        // Role/Route, so first-chat "use this Workspace" invented a
        // set_settings write. Hermes workspace is host-pinned. Empty stays
        // isolation-only plus this honesty. Dest Source title left.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let workspace = BotWorkspaceHonesty(name: "macos-app", cwd: "/tmp/macos-app")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Use /tmp/other as your Workspace",
            workspace: workspace
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.workspaceHostAssignedHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app)."))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Workspace"),
            "tools must not advertise a workspace write"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Desktop"),
            "tools must not advertise a Desktop write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.workspaceHostAssignedHonesty),
            "workspace honesty is a compiler layer, not starter soul"
        )
    }

    func test_desktopHonestyCompilesSeparateFromWorkspace_becauseStudioDesktopIsNotAHop() {
        // WHY: Studio already says Desktop. Compile folded isolation into
        // Workspace, so first-chat "which Desktop?" invented a hop. Hermes
        // agents know their execution space even when SOUL.md is custom.
        // Leftover VM kinds still compile as Logical execution space.
        // Dest Source title left on Working space.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let leftover = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .dedicatedLocalVM,
            digest: "x"
        )
        let workspace = BotWorkspaceHonesty(name: "macos-app", cwd: "/tmp/macos-app")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which Desktop?",
            workspace: workspace
        )
        let leftoverReceipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: leftover,
            userText: "Which Desktop?"
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            leftoverReceipt.layers.first(where: { $0.title == "Desktop" })?.text,
            "\(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
        )
        XCTAssertFalse(leftoverReceipt.compiledPayload.contains("Dedicated local VM"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Desktop:"),
            "Desktop honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Desktop"),
            "tools must not advertise a Desktop write"
        )
    }

    func test_emptySoulFallsBackToStandingDefault_becauseANewAgentMustNotCompileSoulless() {
        // WHY: Hermes seeds SOUL.md and falls back when it is empty. OpenClaw
        // seeds SOUL.md on first run. Live Desk Brain showed "No standing
        // instructions" / Excluded for New Agent — the model only saw
        // "You are New Agent." A jobless teammate still needs standing rules.
        let bot = BotDefinition(handle: "new-agent", name: "New Agent", title: "", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "New Agent",
            title: "",
            description: "",
            soul: "",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "qual seu nome?")
        let composed = BotBrainCompiler.composeRunPrompt(bot: bot, revision: revision, userText: "qual seu nome?")
        XCTAssertEqual(receipt.compiledPayload, composed)
        XCTAssertTrue(receipt.compiledPayload.contains("You are New Agent (@new-agent)."))
        XCTAssertTrue(receipt.compiledPayload.contains("Instructions:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Standing instructions:"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        let layer = receipt.layers.first { $0.kind == .soul }
        XCTAssertEqual(layer?.included, true)
        XCTAssertEqual(layer?.text, BotStandingInstructions.fallback(name: "New Agent", title: "", description: ""))
        XCTAssertTrue(layer?.reason.contains("Built-in teammate default") == true)
    }

    func test_publishedSoulReplacesFallback_becauseCustomInstructionsStayTheEscapeHatch() {
        // WHY: Auto-config must not hide power. A written soul is identity;
        // the starter must not leak into the payload beside it.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Hi")
        XCTAssertTrue(receipt.compiledPayload.contains("Be brief."))
        XCTAssertTrue(receipt.compiledPayload.contains("Instructions:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Standing instructions:"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first { $0.kind == .soul }?.reason, "Standing instructions are published with the revision.")
    }

    func test_generatedSoulPicksUpRole_becauseJobIsAutoConfigNotASecondForm() {
        // WHY: Role still shapes identity. The starter must not repeat
        // "You are … Your job is" — that was a second identity form.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Reviews PRs", description: "")
        let starter = BotStandingInstructions.fallback(name: "Piper", title: "", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Reviews PRs",
            description: "",
            soul: starter,
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Go")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Reviews PRs."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.admittedToolsText))
        XCTAssertFalse(starter.contains(BotStandingInstructions.rememberFactTool), "tools layer owns remember")
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper. Your job is:"))
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Reviews PRs."))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(starter))
        XCTAssertFalse(BotStandingInstructions.looksGenerated("Speak plainly."))
    }

    func test_fullAccessReceiptResolvesToFullAccess_becauseBotsDefaultToIt() {
        // WHY: Bots default to Full access. The compiled Approval mode must
        // match the mode the run really uses, or the model would be told it
        // cannot act while it can, or the reverse.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let leftover = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .fullAccess,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: leftover, userText: "Just write the file")
        XCTAssertEqual(receipt.permissionMode, .fullAccess)
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText(for: .fullAccess))"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalModeHostAssignedHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertFalse(receipt.compiledPayload.contains("Permission:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("full_access"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.text, BotBrainCompiler.approvalModeText(for: .fullAccess))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .permission })?.reason,
            "Advertised supervised route. Leftover full-access kinds compile as supervised."
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Approval mode"),
            "tools must not advertise an Approval mode write"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Approvals"),
            "tools must not advertise an Approvals write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.approvalModeHostAssignedHonesty),
            "approval-mode honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.approvalsHonesty),
            "approvals honesty is a compiler layer, not starter soul"
        )
    }

    func test_liveFullAccessChipCompilesFullAccessHonesty_becauseComposerIsTheRunMode() {
        // WHY: Desk send already forwarded fullAccess to the provider while
        // Approval mode still said Supervised. Host-brokered writes stay off
        // made the model refuse a Full access turn.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Just write the file",
            liveRunMode: .fullAccess
        )
        XCTAssertEqual(receipt.permissionMode, .fullAccess)
        XCTAssertTrue(receipt.compiledPayload.contains("Full access. Run tools without asking."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalModeHostAssignedHonesty))
        XCTAssertFalse(receipt.compiledPayload.contains(BotPermission.honestyLabel))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .permission })?.reason,
            "Live composer chip. Host-assigned. Not a self-config write."
        )
    }

    func test_approvalsHonestyCompilesForCustomSoul_becauseAllowOnceIsNotAnEscapeHatch() {
        // WHY: Studio Security already says Approvals and Allow once / Deny
        // stay off until P1b. Compile listed Approval mode only, so
        // first-chat "Allow once" invented a grant. Dest Source title stays
        // Permission. Tools do not advertise a write.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Allow once")
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Allow once / Deny stay off until P1b"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("Permission:"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.text, BotBrainCompiler.approvalModeText())
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Allow once"),
            "tools must not advertise an Allow once write"
        )
    }

    func test_handleHonestyCompilesForCustomSoul_becauseDeskAddressIsNotAnEscapeHatch() {
        // WHY: Desk already shows @handle. Brain compile never sent it, so
        // first-chat "what's your handle?" invented one. Handle is advertised
        // identity — a written soul must not hide it.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your handle?")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout."))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout. Avatar: Auto."
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.reason,
            "Name, handle, role, and avatar compile into the identity line."
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.handleCreateOnlyHonesty))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("@piper"),
            "handle honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.handleCreateOnlyHonesty),
            "create-only honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("handle,")
                || BotStandingInstructions.admittedToolsText.contains("or handle"),
            "handle stays create-only; tools must not persist it"
        )
    }

    func test_emptyHandleOmitsCreateOnlyHonesty_becauseCompileMustNotAdvertiseNone() {
        // WHY: Studio Handle can be blank before first save. Compile must
        // omit create-only honesty, not invent a handle persist story.
        let bot = BotDefinition(handle: "", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Change your handle")
        XCTAssertEqual(
            receipt.compiledPayload.split(separator: "\n").first.map(String.init),
            "You are Piper. Role: Scout. Avatar: Auto."
        )
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.handleCreateOnlyHonesty))
    }

    func test_roleHonestyCompilesForCustomSoul_becauseStudioRoleIsNotAnEscapeHatch() {
        // WHY: Studio already says Role. Compile put the job unlabeled after
        // an em-dash, so first-chat "what's your Role?" invented a hop. A
        // written soul must not hide the advertised job.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your Role?")
        XCTAssertTrue(receipt.compiledPayload.contains("Role: Scout"), "Role: Scout")
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout. Avatar: Auto."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Role:"),
            "role honesty is a compiler layer, not starter soul"
        )
    }

    func test_emptyRoleDoesNotInventAJob_becauseCompileMustNotAdvertiseNone() {
        // WHY: Studio Role can be empty. Compile must omit the label, not
        // invent "No job yet" from dest chrome.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "  ", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "  ",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your Role?")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Role:"))
        XCTAssertFalse(receipt.compiledPayload.contains("No job yet"))
    }

    func test_avatarHonestyCompilesForCustomSoul_becauseStudioAvatarIsNotAnEscapeHatch() {
        // WHY: Studio already picks Avatar and tools already persist it.
        // Brain compile never sent the chip, so first-chat "what's my avatar?"
        // invented a symbol. A written soul must not hide the advertised chip.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.avatarSymbol = "star.fill"
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's my avatar?")
        XCTAssertTrue(receipt.compiledPayload.contains("Avatar: Star"), "Avatar: Star")
        XCTAssertFalse(receipt.compiledPayload.contains("star.fill"), "leftover SF")
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout. Avatar: Star."
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.reason,
            "Name, handle, role, and avatar compile into the identity line."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Avatar:"),
            "avatar honesty is a compiler layer, not starter soul"
        )
    }

    func test_avatarHonestyCompilesBlobatar_becauseStudioComposerMustNotLeakTheToken() {
        // WHY: Studio writes blobatar:v1:cloud:…. First-chat "what's my
        // avatar?" must hear Cloud, never the token.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.avatarSymbol = "blobatar:v1:cloud:happy:none:coral"
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's my avatar?")
        XCTAssertTrue(receipt.compiledPayload.contains("Avatar: Cloud"), "Avatar: Cloud")
        XCTAssertFalse(receipt.compiledPayload.contains("blobatar:"), "token stays out")
        XCTAssertFalse(receipt.compiledPayload.contains("star.fill"), "leftover SF")
    }

    func test_leftoverAvatarDoesNotCompileSFSymbol_becauseStudioNeverAdvertisedIt() {
        // WHY: Leftover store symbols are not Studio chips. Compile must not
        // teach the model an SF path the owner never picked.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.avatarSymbol = "bird"
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's my avatar?")
        XCTAssertFalse(receipt.compiledPayload.contains("Avatar:"), "leftover avatar does not compile")
        XCTAssertFalse(receipt.compiledPayload.contains("bird"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout."
        )
    }

    func test_browserHonestyCompilesForCustomSoul_becauseLastWebsiteIsNotAnEscapeHatch() {
        // WHY: Tools already persist last website. Brain compile never sent
        // it, so first-chat "what's open?" invented a hop or a URL. A written
        // soul must not hide the advertised last website.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let browser = BotBrowserTarget(url: "https://github.com/remotecode", title: "GitHub")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What's open?",
            browser: browser
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Browser: GitHub (https://github.com/remotecode)"), "Browser: GitHub")
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .browser })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .browser })?.text,
            "Browser: GitHub (https://github.com/remotecode)"
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .browser })?.reason,
            "Advertised last website. Tools already persist it."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Browser:"),
            "browser honesty is a compiler layer"
        )
    }

    func test_emptyBrowserDoesNotInventAURL_becauseCompileMustNotAdvertiseNone() {
        // WHY: No last website is not "None". Compile must omit the layer
        // so first-chat cannot treat an empty browser as a page.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let blank = BotBrowserTarget(url: "  ", title: "  ")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What's open?",
            browser: blank
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Browser:"), "empty browser")
        XCTAssertNil(receipt.layers.first(where: { $0.kind == .browser }))
        XCTAssertFalse(receipt.compiledPayload.contains("None"))
    }

    func test_browserHonestyOmitsCookies_becauseWebsiteDataIsNotACompileLayer() {
        // WHY: get already returns website-data keys. Compile must not dump
        // cookies into the adapter payload.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let page = BotBrowserPageState(
            url: "https://github.com/remotecode",
            title: "GitHub",
            cookies: ["session": "secret-token"]
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What's open?",
            browser: BotBrowserTarget(url: page.url, title: page.title)
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Browser: GitHub (https://github.com/remotecode)"))
        XCTAssertFalse(receipt.compiledPayload.contains("secret-token"), "cookies stay out")
        XCTAssertFalse(receipt.compiledPayload.contains("session"))
    }

    func test_compileOmitsDefaultRoute() {
        // WHY: Studio no longer publishes a provider. Compiling Default
        // route would lock the teammate to Claude/Codex/Grok in every
        // provider turn.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Hi")
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Model: opus"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.computerUseObservationTool))
    }

    func test_receiptUsesCallingRunRouteWithoutCompilingItIntoBotIdentity() {
        // WHY: provider/model describe this invocation, not the Bot. The
        // receipt must record the caller's route for audit while the Bot prompt
        // and identity layers remain route-free.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What model is running this turn?",
            runProvider: .grok,
            runModel: "grok-4.6"
        )
        XCTAssertEqual(receipt.provider, .grok)
        XCTAssertEqual(receipt.model, "grok-4.6")
        XCTAssertFalse(receipt.compiledPayload.contains("Grok"))
        XCTAssertFalse(receipt.compiledPayload.contains("grok-4.6"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
    }

    func test_admittedToolsCompileForCustomSoul_becauseDeskToolsAreNotAnEscapeHatch() {
        // WHY: Desk already admits remember/browse tools. Starter soul used
        // to own those names, so a custom soul hid them and first-chat
        // "remember this" invented a tool. Tools are advertised capability —
        // a written soul must not hide them.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Remember this")
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.admittedToolsText))
        XCTAssertFalse(
            receipt.compiledPayload.contains(BotStandingInstructions.getBrowserTool),
            "browse tools are desktop-gated; an owner's-Chrome bot admits none"
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .tools })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .tools })?.text, BotStandingInstructions.admittedToolsText)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .tools })?.reason,
            "Desk-admitted tools. Custom soul must not hide them."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotStandingInstructions.rememberFactTool),
            "tools layer owns the catalog names"
        )
    }

    func test_admittedToolsCompileNamesDescription_becauseCustomSoulMustNotHideThem() {
        // WHY: Studio already says Model. Tools named route only, so
        // first-chat "change your Model" invented a hop. A custom soul
        // must still see that advertised write.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "Looks around")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Change your description")
        XCTAssertTrue(receipt.compiledPayload.contains("name, Role, Instructions, description, notifications, or avatar"))
        XCTAssertFalse(receipt.compiledPayload.contains("job, standing instructions"), "leftover job is not advertised")
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.changeJobTool))
        XCTAssertTrue(receipt.compiledPayload.contains("Description: Looks around"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .tools })?.text,
            BotStandingInstructions.admittedToolsText
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .description })?.text,
            BotBrainCompiler.descriptionLine("Looks around")
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Description:"),
            "description honesty is a compiler layer, not starter soul"
        )
    }

    func test_emptyDescriptionDoesNotCompile_becauseBlankAboutMustNotInventCopy() {
        // WHY: Studio hides an empty Description. Compile must not invent
        // about text the owner never advertised.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "  ")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "  ",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your description?")
        XCTAssertFalse(receipt.compiledPayload.contains("Description:"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .description })?.included, false)
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
    }

    func test_routeOmitsEmptyModel_becauseDeskHidesAnUnsetModelPill() {
        // WHY: Desk modelLabel is hidden when the revision model is blank.
        // Compile must not invent a default the owner never advertised.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .grok,
            providerInstanceID: "grok",
            model: "  ",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Hi")
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Model:"), "Desk hides the pill")
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
    }

    func test_permissionHonestyCompilesForCustomSoul_becauseRouteHonestyIsNotAnEscapeHatch() {
        // WHY: Working-space honesty is a RemoteCode layer. Permission is
        // the same class of advertised fact — a written soul must not hide
        // that Desk launches supervised.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .autoAcceptEdits,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Can you just do it?")
        XCTAssertEqual(receipt.permissionMode, .supervised)
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("auto_accept_edits"))
        XCTAssertFalse(BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotPermission.honestyLabel))
    }

    func test_activeRoutineCompilesAndOffStaysOut_becauseSchedulesAreAuthority() {
        // WHY: Studio already says Active, Instruction, and When. Compile
        // listed unlabeled prompt + parenthetical note, so first-chat
        // "what's the Instruction?" invented a hop. Hermes agents see the
        // advertised field names. Off rows and app-closed honesty stay.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let morning = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight failures",
            scheduleNote: "Weekdays 9:00"
        )
        let sweep = BotRoutineDefinition(
            botID: bot.id,
            name: "Inbox sweep",
            prompt: "Clear the inbox"
        )
        let off = BotRoutineDefinition(
            botID: bot.id,
            name: "Nightly archive",
            prompt: "Archive the inbox"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What do you run?",
            routines: [
                BotRoutine(
                    definition: morning,
                    activation: BotRoutineActivation(routineID: morning.id, botID: bot.id, isEnabled: true)
                ),
                BotRoutine(
                    definition: sweep,
                    activation: BotRoutineActivation(routineID: sweep.id, botID: bot.id, isEnabled: true)
                ),
                BotRoutine(
                    definition: off,
                    activation: BotRoutineActivation(routineID: off.id, botID: bot.id, isEnabled: false)
                ),
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout."))
        XCTAssertTrue(receipt.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertFalse(receipt.compiledPayload.contains("Active routines"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled routines"))
        XCTAssertTrue(receipt.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00. Active."))
        XCTAssertFalse(receipt.compiledPayload.contains("Morning scan (Weekdays 9:00):"))
        XCTAssertTrue(receipt.compiledPayload.contains("Inbox sweep: Instruction: Clear the inbox. Active."))
        XCTAssertFalse(receipt.compiledPayload.contains("Inbox sweep: Instruction: Clear the inbox. When:"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(morning.id.value)))
        XCTAssertFalse(receipt.compiledPayload.contains("Nightly archive"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(off.id.value)))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Morning scan") })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Morning scan") })?.reason,
            "Active. Runs only while the app is open."
        )
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Nightly archive") })?.included, false)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Nightly archive") })?.reason,
            "Off. Not injected."
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Test run: only when the User request below explicitly asks"))
        XCTAssertTrue(receipt.compiledPayload.contains("Does not set Active"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Morning scan") })?.title, "Routine")
    }

    func test_testRunHonestyCompilesForCustomSoul_becauseStudioTestRunIsNotAHop() {
        // WHY: Studio already says Test run. Compile listed Active routines
        // only, so first-chat "test this routine" invented a hop or a
        // schedule fire. Hermes test runs are live work, not a fake cron.
        // Dest Source title stays Routine. Schema does not grow a test tool.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let morning = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight failures"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Test this routine",
            routines: [
                BotRoutine(
                    definition: morning,
                    activation: BotRoutineActivation(routineID: morning.id, botID: bot.id, isEnabled: true)
                )
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Test run: only when the User request below explicitly asks to test or run a routine"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotRoutineCopy.testRunHonestyCaption))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertFalse(receipt.compiledPayload.contains("bot_test_routine"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Test run"),
            "tools must not advertise a Test run write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Test run:"),
            "compiler layer owns Test run"
        )
        XCTAssertFalse(receipt.layers.contains { $0.title == "Test run" })
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        let empty = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Test this routine")
        XCTAssertTrue(empty.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertFalse(empty.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertFalse(empty.compiledPayload.contains("Active routines"))
        XCTAssertNil(empty.layers.first(where: { $0.kind == .routine }))
    }

    func test_routinesHonestyCompilesForCustomSoul_becauseStudioRoutinesIsNotAHop() {
        // WHY: Studio already says Routines. Compile listed Active routines,
        // so first-chat "what are your Routines?" invented a hop. Hermes
        // agents see the advertised tab name. Active stays on each live
        // line. Dest Source title stays Routine. Schema does not grow a
        // routines tool.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let morning = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight failures",
            scheduleNote: "Weekdays 9:00"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What are your Routines?",
            routines: [
                BotRoutine(
                    definition: morning,
                    activation: BotRoutineActivation(routineID: morning.id, botID: bot.id, isEnabled: true)
                )
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertTrue(receipt.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00. Active."))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("Active routines"))
        XCTAssertFalse(receipt.compiledPayload.contains("bot_list_routines"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Routines (not while"),
            "tools must not advertise a Routines list write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Routines (not while"),
            "compiler layer owns Routines"
        )
        XCTAssertFalse(receipt.layers.contains { $0.title == "Routines" })
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Morning scan") })?.reason,
            "Active. Runs only while the app is open."
        )
    }

    func test_skillsCompileAndOffStaysOut_becauseStudioAlreadySaysSkills() {
        // WHY: Studio already says Skills. Compile listed Enabled skills, so
        // first-chat "which Skills?" invented a hop. Hermes agents see the
        // advertised catalog name. Off stays out.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which Skills?",
            skills: [enabled, disabled]
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "weekly-account-health" })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "off-skill" })?.included, false)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text == "off-skill" })?.reason,
            "Leftover catalog binding. Skills are files."
        )
    }

    func test_memoryMutateKeyCompilesForCustomSoul_becauseForgetMustNotInventAnId() {
        // WHY: Desk already admits bot_forget_memory and requires memory_id.
        // Compile listed the fact without the key, so first-chat "forget this"
        // invented a UUID or a hidden get-settings hop. Hermes memory is in
        // context with enough to act. A written soul must not hide the key.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let live = BotMemoryFileText(path: "MEMORY.md", body: "Prefers dark mode")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Forget the dark-mode fact",
            memoryFiles: [live]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(receipt.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.memoryFileLine(live)))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.text, BotBrainCompiler.memoryFileLine(live))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.included, true)
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.writeMemoryFileTool))
    }

    func test_fileMemoryCompilesFromMarkdownNotStoreFacts() {
        // WHY: Store Fact UUID lines hid the files the bot is supposed to
        // edit. Compile must inject MEMORY.md and today's note as files.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let files = [
            BotMemoryFileText(path: "MEMORY.md", body: "- Prefers dark mode\n"),
            BotMemoryFileText(path: "memory/2026-08-18.md", body: "Shipped the overnight brief.\n"),
        ]
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What do you remember?",
            memoryFiles: files
        )
        XCTAssertTrue(receipt.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains("### memory/2026-08-18.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Shipped the overnight brief."))
        XCTAssertFalse(receipt.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertEqual(receipt.memoryLayers.count, 2)
        XCTAssertTrue(receipt.memoryLayers.allSatisfy(\.included))
    }

    func test_ownedSkillFilesCompileWithoutCatalogAdd() {
        // WHY: Catalog Add hid the markdown the bot is supposed to edit.
        // Compile must inject skills/<slug>/SKILL.md and leave leftover
        // bindings out of the payload.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let leftover = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let owned = BotOwnedSkillText(
            slug: "weekly-invoice",
            body: "---\nname: weekly-invoice\ndescription: Invoice the week.\n---\nSECRET WEEKLY BODY\n"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Run the invoice skill",
            skills: [leftover],
            ownedSkills: [owned]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Skills:"))
        XCTAssertTrue(receipt.compiledPayload.contains("weekly-invoice"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.viewSkillTool))
        XCTAssertTrue(receipt.compiledPayload.contains("Invoice the week."))
        XCTAssertFalse(receipt.compiledPayload.contains("SECRET WEEKLY BODY"))
        XCTAssertFalse(receipt.compiledPayload.contains("### skills/weekly-invoice/SKILL.md"))
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Bot skills:"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.id == "skill-weekly-account-health" })?.included,
            false
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.id == "owned-skill-weekly-invoice" })?.included,
            true
        )
        XCTAssertTrue(receipt.compiledPayload.contains("skills/<slug>/SKILL.md"))
    }

    func test_notificationsHonestyCompilesForCustomSoul_becauseStudioToggleIsNotAnEscapeHatch() {
        // WHY: Studio already shows Notifications On/Off. The model never
        // saw it, so first-chat "will you notify me?" invented alerts. A
        // written soul must not hide advertised notification power.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.notificationsEnabled = true
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Will you notify me?")
        XCTAssertTrue(receipt.compiledPayload.contains("Notifications: \(BotBrainCompiler.notificationsLine(enabled: true))"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .notifications })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .notifications })?.text,
            BotBrainCompiler.notificationsLine(enabled: true)
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Notifications:"),
            "notifications honesty is a compiler layer, not starter soul"
        )
    }

    func test_notificationsOffDoesNotCompileLiveAlerts_becauseOffMustStayOff() {
        // WHY: Off is advertised. Compiling On copy when the toggle is Off
        // would invent alerts the owner already turned off.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.notificationsEnabled = false
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Ping me when you are blocked")
        XCTAssertTrue(receipt.compiledPayload.contains("Notifications: \(BotBrainCompiler.notificationsLine(enabled: false))"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.notificationsLine(enabled: true)))
        XCTAssertFalse(receipt.compiledPayload.contains("Notifications: On"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .notifications })?.text,
            BotBrainCompiler.notificationsLine(enabled: false)
        )
    }

    func test_compileIncludesBotOwnedSkillFiles() {
        // WHY: This-bot SKILL.md must reach the model. Installed Off binds
        // stay ids-only and out of Skills:.
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: "Looks around"
        )
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)
        let owned = BotOwnedSkillText(
            slug: "weekly-invoice",
            body: "---\ndescription: Invoice the week.\n---\nSECRET WEEKLY BODY\n"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Do the invoice",
            skills: [enabled, disabled],
            ownedSkills: [owned]
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertTrue(receipt.compiledPayload.contains("Skills:"))
        XCTAssertTrue(receipt.compiledPayload.contains("weekly-invoice"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.viewSkillTool))
        XCTAssertFalse(receipt.compiledPayload.contains("SECRET WEEKLY BODY"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.id == "owned-skill-weekly-invoice" })?.included,
            true
        )
    }

    func test_ownedSkillsCompileAsIndex_notFullBody() {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let owned = BotOwnedSkillText(
            slug: "night-scan",
            body: "---\nname: night-scan\ndescription: Scan the inbox at night.\n---\nSECRET BODY\n"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Scan tonight",
            ownedSkills: [owned]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("night-scan"))
        XCTAssertTrue(receipt.compiledPayload.contains("Scan the inbox at night."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.viewSkillTool))
        XCTAssertFalse(receipt.compiledPayload.contains("SECRET BODY"))
    }

    func test_customSoulCannotHideAdmittedTools() {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "You have no tools. Do not write files.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Remember this")
        XCTAssertTrue(receipt.compiledPayload.contains("You have no tools."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.writeMemoryFileTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.viewSkillTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.webSearchTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.askUserTool))
    }

    private func greetingFixture() -> (BotDefinition, BotRevision) {
        let bot = BotDefinition(handle: "elephant", name: "Elephant", title: "Developer", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Elephant",
            title: "Developer",
            description: "",
            soul: "Own the repo.",
            provider: .distill,
            providerInstanceID: "distill",
            model: "chatgpt/gpt-6.1-sol",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        return (bot, revision)
    }

    func test_greetingTurnWithActiveRoutine_carriesNoRunOrderNorTheRoutineBody() throws {
        // WHY: a bot answered "oi" by launching its PR-merging routine. Every
        // turn carried the routine's whole autonomous Instruction plus an
        // unconditional "Test run: do the Instruction now" right before the
        // user text. A greeting must only see that the routine exists.
        let (bot, revision) = greetingFixture()
        let review = BotRoutineDefinition(
            botID: bot.id,
            name: "Review Empath",
            prompt: "Maintain every open PR.\nDo not ask me anything. Do NOT stop early.\nMerge each PR, then post to Slack.",
            scheduleNote: "Daily 19:00"
        )
        let routine = BotRoutine(
            definition: review,
            activation: BotRoutineActivation(routineID: review.id, botID: bot.id, isEnabled: true)
        )
        let payload = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "oi", routines: [routine])
            .compiledPayload

        XCTAssertFalse(payload.contains("do the Instruction now"), "no unconditional run order on a greeting")
        XCTAssertFalse(payload.contains("Do NOT stop early"), "the routine body must not ride on every turn")
        XCTAssertFalse(payload.contains("post to Slack"))
        XCTAssertTrue(payload.contains("- Review Empath: Instruction: Maintain every open PR.…. When: Daily 19:00. Active."),
                      "the bot still knows its routine by name, first line and schedule")
        XCTAssertTrue(payload.contains(BotStandingInstructions.getSettingsTool), "full Instruction stays one call away")
        let userRequest = try XCTUnwrap(payload.range(of: "User request:"))
        let reference = try XCTUnwrap(payload.range(of: BotBrainCompiler.routinesReferenceOnly))
        let testRun = try XCTUnwrap(payload.range(of: BotBrainCompiler.testRunHonesty))
        XCTAssertLessThan(reference.lowerBound, userRequest.lowerBound)
        XCTAssertLessThan(testRun.lowerBound, userRequest.lowerBound)
        XCTAssertTrue(BotBrainCompiler.testRunHonesty.contains("only when the User request below explicitly asks"))
        XCTAssertTrue(BotBrainCompiler.testRunHonesty.contains("A greeting or an unrelated request never starts a routine"))
    }

    func test_longSingleLineRoutineInstructionIsCapped_becauseOneLineCanStillBeAWholeRunbook() {
        let (bot, revision) = greetingFixture()
        let runbook = "You are an autonomous GitHub PR maintenance agent " + String(repeating: "and you merge everything ", count: 40)
        let definition = BotRoutineDefinition(botID: bot.id, name: "Runbook", prompt: runbook)
        let routine = BotRoutine(
            definition: definition,
            activation: BotRoutineActivation(routineID: definition.id, botID: bot.id, isEnabled: true)
        )
        let payload = BotBrainCompiler.composeRunPrompt(bot: bot, revision: revision, userText: "oi", routines: [routine])

        XCTAssertFalse(payload.contains(runbook.trimmingCharacters(in: .whitespaces)))
        let summary = BotBrainCompiler.routineInstructionSummary(runbook)
        XCTAssertTrue(summary.hasPrefix("You are an autonomous GitHub PR maintenance agent"))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThanOrEqual(summary.count, BotBrainCompiler.routineInstructionSummaryLimit + 1)
        XCTAssertEqual(BotBrainCompiler.routineInstructionSummary("  Scan overnight failures \n"), "Scan overnight failures",
                       "a short one-line Instruction is shown whole, with no cut marker")
    }

    func test_runPromptAsksForNaturalHumanRepliesBeforeInstructions() throws {
        // WHY: Distill bots answered "Bom dia. Página Ratel aberta no Chrome.
        // Fala tarefa." The turn payload carried no reply style at all; it now
        // asks for natural, complete sentences in the user's language on every
        // provider, ahead of Instructions so a custom soul still has the last word.
        // Caveman no longer shapes Bot replies; the flag is ignored here.
        var (bot, revision) = greetingFixture()
        bot.cavemanEnabled = false
        let payload = BotBrainCompiler.composeRunPrompt(bot: bot, revision: revision, userText: "bom dia")
        let style = try XCTUnwrap(payload.range(of: BotStandingInstructions.replyStyleLine))
        let instructions = try XCTUnwrap(payload.range(of: "Instructions:"))
        XCTAssertLessThan(style.lowerBound, instructions.lowerBound)
        XCTAssertTrue(BotStandingInstructions.replyStyleLine.contains("in the user's language"))
        XCTAssertTrue(BotStandingInstructions.replyStyleLine.contains("complete sentences with articles"))
        XCTAssertTrue(BotStandingInstructions.replyStyleLine.contains("No telegraphic fragments"))
    }
}

/// Per-Bot reply style (2026-10-15): what each Bot is told about how to write.
final class BotReplyStylePromptTests: XCTestCase {
    private func prompt(for bot: BotDefinition) -> String {
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: bot.name,
            title: "Developer",
            description: "",
            soul: "",
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x",
            publishedAt: Date(timeIntervalSince1970: 0)
        )
        return BotBrainCompiler.composeRunPrompt(bot: bot, revision: revision, userText: "oi")
    }

    func test_cavemanFlagDoesNotShapeSimpleReplies() {
        // WHY: Caveman telegraphed replies for owners who are not technical;
        // a stored caveman flag must not change the Simple prompt.
        var bot = BotDefinition(handle: "ceo", name: "Ceo", title: "", description: "")
        bot.verbosity = .human
        XCTAssertTrue(bot.cavemanEnabled)
        let payload = prompt(for: bot)
        XCTAssertTrue(payload.contains(BotStandingInstructions.replyStyleLine))
        XCTAssertTrue(payload.contains(BotStandingInstructions.humanVerbosityLine))
        XCTAssertTrue(payload.contains(BotStandingInstructions.choicesLine))
        XCTAssertFalse(payload.contains(BotStandingInstructions.cavemanStyleLine))
    }

    func test_titioWritesFullSentencesByDefault() {
        let titio = BotDefinition(handle: TitioIdentity.handle, name: "Titio", title: "", description: "")
        XCTAssertFalse(titio.cavemanEnabled, "Titio explains RemoteCode, so it is not caveman")
        let payload = prompt(for: titio)
        XCTAssertTrue(payload.contains(BotStandingInstructions.replyStyleLine))
        XCTAssertFalse(payload.contains(BotStandingInstructions.cavemanStyleLine))
    }

    func test_humanVerbosityGetsHumanizerRulesAndVerboseDoesNot() {
        // WHY: Human hides tool rows, so the Bot must not narrate commands the
        // user cannot see; Verbose keeps today's prompt.
        var bot = BotDefinition(handle: "dev", name: "Dev", title: "", description: "")
        XCTAssertEqual(bot.verbosity, .verbose, "new Bots reply Technical by default")
        bot.verbosity = .human
        XCTAssertTrue(prompt(for: bot).contains(BotStandingInstructions.humanVerbosityLine))
        XCTAssertTrue(BotStandingInstructions.humanVerbosityLine.contains("never narrate your process"))
        bot.verbosity = .verbose
        XCTAssertFalse(prompt(for: bot).contains(BotStandingInstructions.humanVerbosityLine))
        XCTAssertTrue(prompt(for: bot).contains(BotStandingInstructions.technicalVerbosityLine))
        XCTAssertFalse(prompt(for: bot).contains(BotStandingInstructions.cavemanStyleLine))
    }

    func test_everyBotIsTaughtTheChoicesBlockTheChatParses() throws {
        // WHY: the example in the prompt must be a block the chat really turns
        // into a card, or Bots would learn a format nothing renders.
        let payload = prompt(for: BotDefinition(handle: "dev", name: "Dev", title: "", description: ""))
        XCTAssertTrue(payload.contains(BotStandingInstructions.choicesLine))
        let example = BotStandingInstructions.choicesLine
        let start = try XCTUnwrap(example.range(of: "```choices"))
        let end = try XCTUnwrap(example.range(of: "```", range: start.upperBound..<example.endIndex))
        let block = String(example[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "\\n", with: "\n")
        let parsed = BotChoicesBlock.parse("Pick one\n" + block)
        XCTAssertEqual(parsed.text, "Pick one")
        XCTAssertEqual(parsed.choices?.options, ["First option", "Second option"])
    }

    func test_botsEncodedBeforeReplyStyleStillDecodeWithTheDefaults() throws {
        // WHY: encoded Bots from older builds must keep decoding.
        let bot = BotDefinition(handle: "titio", name: "Titio", title: "", description: "")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bot)) as? [String: Any])
        object.removeValue(forKey: "verbosity")
        object.removeValue(forKey: "cavemanEnabled")
        let decoded = try JSONDecoder().decode(BotDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.verbosity, .human)
        XCTAssertFalse(decoded.cavemanEnabled)
    }
}
