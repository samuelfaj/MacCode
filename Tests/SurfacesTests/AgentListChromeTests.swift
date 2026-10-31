import XCTest

final class AgentListChromeTests: XCTestCase {
    func test_sharedTypesOwnListChrome_becauseFourOverviewsMustNotRepaintCapsules() throws {
        // WHY: dest Schedule Tasks / Active Bots and agentic Schedule Tasks /
        // Active Threads used to copy accent chips, search, footer, 44pt cards,
        // and the travel-pause switch. The Surfaces type owns that look.
        let chrome = try source("Sources/Surfaces/AgentListChrome.swift")
        XCTAssertTrue(chrome.contains("struct AgentListFilterChip"))
        XCTAssertTrue(chrome.contains("struct AgentListSearchField"))
        XCTAssertTrue(chrome.contains("autofocus: Bool = false"),
                      "search owns optional autofocus so overview screens do not fork the field")
        XCTAssertTrue(chrome.contains(".focused($focused)"),
                      "autofocus must bind FocusState onto the TextField")
        XCTAssertTrue(chrome.contains("if autofocus { focused = true }"),
                      "opening an autofocus overview must claim the field without a click")
        XCTAssertTrue(chrome.contains("struct AgentListFooterBar"))
        XCTAssertTrue(chrome.contains("struct AgentKillSwitchControl"))
        XCTAssertTrue(chrome.contains("struct AgentOverviewCard"))
        XCTAssertTrue(chrome.contains("bolt.fill"))
        XCTAssertTrue(chrome.contains("pause.fill"))
        XCTAssertTrue(chrome.contains("Travel pause"))
        XCTAssertTrue(chrome.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(chrome.contains("DS.Palette.accent"))
        XCTAssertTrue(chrome.contains("DS.Palette.onAccent"))
        XCTAssertTrue(
            chrome.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "overview cards occupy one complete line, not a hugging capsule"
        )
    }

    func test_destAndAgenticScheduleMountSharedChrome() throws {
        // WHY: both schedule overviews must call the shared types, not keep
        // private filterChip / searchField paint. Editors must use composer
        // capsules instead of Picker("Provider").
        let dest = try source("Sources/AppShell/BotScheduleTasksWindow.swift")
        let agent = try source("Sources/AppShell/ScheduledTasksWindow.swift")

        for (label, text) in [("dest", dest), ("agent", agent)] {
            XCTAssertTrue(text.contains("AgentListFilterChip("), "\(label) missing filter chip")
            XCTAssertTrue(text.contains("AgentListSearchField("), "\(label) missing search field")
            XCTAssertTrue(text.contains("AgentListFooterBar("), "\(label) missing footer")
            XCTAssertTrue(text.contains("AgentKillSwitchControl("), "\(label) missing kill switch")
            XCTAssertTrue(text.contains("AgentOverviewCard("), "\(label) missing overview card")
            XCTAssertTrue(text.contains("AgentSourceCapsule("), "\(label) missing source capsule")
            XCTAssertTrue(
                text.contains("AgentModelPopoverChrome(") && text.contains("AgentModelPillLabel("),
                "\(label) missing model pill/popover"
            )
            XCTAssertFalse(text.contains("private func filterChip("), "\(label) still paints a private chip")
            XCTAssertFalse(text.contains("Picker(\"Provider\""), "\(label) still uses Provider picker")
            XCTAssertFalse(text.contains("Picker(\"Model\""), "\(label) still uses Model picker")
            XCTAssertFalse(text.contains("Picker(\"Reasoning\""), "\(label) still uses Reasoning picker")
        }

        XCTAssertTrue(agent.contains("AgentRunAsUserCapsule("))
        XCTAssertTrue(agent.contains("AgentRunAsUser(generatedUID: \"\", shortName: name, uid: uid, gid: 0, homePath: homeDirectory)"))
        XCTAssertFalse(agent.contains("Picker(\"System user\""))
        XCTAssertFalse(agent.contains("scheduledTasks.editor.providerAccount"))
        XCTAssertTrue(agent.contains("schedulerActiveControl"))
        XCTAssertTrue(agent.contains("scheduledTasks.globalActive"))
        XCTAssertTrue(agent.contains("scheduledTasks.editor.provider"))
        XCTAssertTrue(agent.contains("scheduledTasks.editor.autoRouting"))
        XCTAssertTrue(agent.contains("editorGroup(\"Details\")"))
        XCTAssertTrue(agent.contains("editorGroup(\"Frequency\")"))
        XCTAssertTrue(agent.contains("Auto selects the best model for the selected provider at run time."))
        // WHY: the Frequency rows and their ids live in the one shared editor.
        XCTAssertTrue(dest.contains("ScheduledFrequencyEditor("))
        XCTAssertTrue(dest.contains("identifierPrefix: \"bots.scheduleTasks.editor\""))
        XCTAssertTrue(dest.contains("bots.scheduleTasks.editor.provider"))
        XCTAssertTrue(dest.contains("bots.scheduleTasks.editor.autoRouting"))
        XCTAssertTrue(dest.contains("bots.scheduleTasks.editor.reasoning"))
        XCTAssertTrue(dest.contains("struct BotScheduleSpecEditor"))
        XCTAssertTrue(dest.contains("bots.scheduleTasks.globalActive"))

        let destProvider = try XCTUnwrap(dest.range(of: "bots.scheduleTasks.editor.provider"))
        // Distill routes manually, so the dest Auto model row is gated on a non-Distill provider.
        let destAuto = try XCTUnwrap(dest.range(of: "if spec.provider != .distill && spec.routingMode == .auto"))
        XCTAssertLessThan(destProvider.lowerBound, destAuto.lowerBound)

        let agentProvider = try XCTUnwrap(agent.range(of: "scheduledTasks.editor.provider"))
        let agentAuto = try XCTUnwrap(agent.range(of: "if draft.routingMode == .auto"))
        XCTAssertLessThan(agentProvider.lowerBound, agentAuto.lowerBound)
    }

    func test_activeBotsAndThreadsMountSharedChrome() throws {
        // WHY: dest Active Bots and agentic Active Threads are the same list
        // chrome. Cards stay named wrappers that mount AgentOverviewCard.
        let bots = try source("Sources/AppShell/ActiveBotsWindow.swift")
        let threads = try source("Sources/AppShell/ActiveThreadsWindow.swift")

        XCTAssertTrue(bots.contains("AgentListFilterChip("))
        XCTAssertTrue(bots.contains("AgentListSearchField("))
        XCTAssertTrue(bots.contains("AgentListFooterBar("))
        XCTAssertTrue(bots.contains("AgentOverviewCard("))
        XCTAssertFalse(bots.contains("private func filterChip("))
        XCTAssertTrue(bots.contains("struct ActiveBotCard"))
        XCTAssertTrue(bots.contains("struct FinishedBotCard"))
        XCTAssertTrue(bots.contains(".accessibilityLabel(\"Search bots\")"))

        XCTAssertTrue(threads.contains("AgentListFilterChip("))
        XCTAssertTrue(threads.contains("AgentListFooterBar("))
        XCTAssertTrue(threads.contains("AgentOverviewCard("))
        XCTAssertTrue(threads.contains("struct ActiveThreadCard"))
        XCTAssertTrue(threads.contains("struct FinishedThreadCard"))
        XCTAssertTrue(threads.contains("activeThreads.tab."))
    }

    func test_namedCardWrappersStillExist_becauseExistingTestsGrepThoseTypes() throws {
        let agent = try source("Sources/AppShell/ScheduledTasksWindow.swift")
        let dest = try source("Sources/AppShell/BotScheduleTasksWindow.swift")
        XCTAssertTrue(agent.contains("ScheduledTaskCard("))
        XCTAssertTrue(dest.contains("BotScheduleTaskCard("))
        XCTAssertTrue(agent.contains("private struct ScheduledTaskCard"))
        XCTAssertTrue(dest.contains("struct BotScheduleTaskCard"))
    }

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
