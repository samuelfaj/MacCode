import XCTest

/// Source-contract tests for File > Open Recent workspace routing.
///
/// WHY: Open Recent is populated by AppKit, but RemoteCode owns the menu
/// placement and the delegate path that turns selected recent folders into
/// workspaces. A drift here makes recently opened projects disappear from the
/// native File menu or routes them as inert files instead of workspace folders.
final class AppMenuOpenRecentTests: XCTestCase {
    private func appDelegateSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // AppShellTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let sourceURL = repoRoot
            .appendingPathComponent("Sources/AppShell/AppDelegate.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func test_fileMenuDefinesOpenRecentSubmenuWithClearMenuAction() throws {
        let source = try appDelegateSource()

        let fileMenu = try XCTUnwrap(source.range(of: "let fileMenu = NSMenu(title: L(\"File\"))"))
        let openRecent = try XCTUnwrap(source.range(of: "let openRecent = NSMenuItem(title: L(\"Open Recent\"), action: nil, keyEquivalent: \"\")"))
        let openRecentMenu = try XCTUnwrap(source.range(of: "let openRecentMenu = NSMenu(title: L(\"Open Recent\"))"))
        let clearRecent = try XCTUnwrap(source.range(of: "Selector((\"clearRecentDocuments:\"))"))

        XCTAssertLessThan(fileMenu.lowerBound, openRecent.lowerBound,
                          "Open Recent must live under the File menu so macOS users find recent workspaces in the standard location")
        XCTAssertLessThan(openRecent.lowerBound, openRecentMenu.lowerBound,
                          "the Open Recent item must own an Open Recent submenu, not route directly to a custom action")
        XCTAssertLessThan(openRecentMenu.lowerBound, clearRecent.lowerBound,
                          "the submenu must expose AppKit's clearRecentDocuments: action so users can clear stale workspace folders")
    }

    func test_openDocumentDelegateRoutesFoldersThroughWorkspaceCreation() throws {
        let source = try appDelegateSource()

        XCTAssertTrue(source.contains("public func application(_ application: NSApplication, open urls: [URL]) {\n        openDroppedWorkspaceFolders(urls)\n    }"),
                      "recent-document URL opens must route through openDroppedWorkspaceFolders so File > Open Recent creates workspaces")
        XCTAssertTrue(source.contains("public func application(_ sender: NSApplication, openFile filename: String) -> Bool {\n        openDroppedWorkspaceFolders([URL(fileURLWithPath: filename, isDirectory: true)])\n    }"),
                      "single file-open delegate calls must treat the selected recent item as a directory workspace")
        XCTAssertTrue(source.contains("public func application(_ sender: NSApplication, openFiles filenames: [String])"),
                      "multi-open delegate support must exist so AppKit can report success/failure for batch recent-folder opens")
        XCTAssertTrue(source.contains("sender.reply(toOpenOrPrint: opened ? .success : .failure)"),
                      "multi-open delegate calls must reply to AppKit so failed recent-folder opens do not appear successful")
    }

    func test_workspaceCreationFeedsNativeRecentDocuments() throws {
        let source = try appDelegateSource()

        XCTAssertTrue(source.contains("NSDocumentController.shared.noteNewRecentDocumentURL(url)"),
                      "workspace creation paths must feed NSDocumentController so folders appear in File > Open Recent")
        XCTAssertTrue(source.contains("if (try? router.createWorkspace(fromFolder: url)) != nil"),
                      "external folder-open paths must create real workspaces before recording a recent document")
    }
}
