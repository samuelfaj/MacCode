import Darwin
import Foundation
import XCTest
@testable import CoreModel

final class ChromeProfileComputerUseTests: XCTestCase {
    func testInstallerUsesPackagedResourcesAndOnlyRegistersItsOwnExtension() throws {
        // WHY: Settings > Computer Use copies the extension shipped inside MacCode and registers
        // the native host for MacCode's fixed extension ID only. Any other origin would let an
        // unrelated extension drive the user's signed-in Chrome profile.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-chrome-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("MacCode.app/Contents")
        let resources = contents.appendingPathComponent("Resources/RemoteCode_CoreModel.bundle/ChromeComputerUse")
        try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CoreModel/Resources/ChromeComputerUse")
        try FileManager.default.copyItem(at: source, to: resources)
        let home = root.appendingPathComponent("test-user")
        XCTAssertFalse(ChromeProfileConnection.isRegistered(homeDirectory: home))
        let executable = contents.appendingPathComponent("MacOS/RemoteCodeDistillService").path
        let installed = try ChromeProfileConnection.install(executable: executable, homeDirectory: home)
        XCTAssertEqual(installed.path, home.appendingPathComponent("Library/Application Support/RemoteCode/ChromeComputerUse/extension").path)
        // Chrome loads the folder as a whole: a file left behind (a default_locale's messages, a
        // script) makes Load unpacked fail, so every shipped file must arrive.
        let shippedFiles = Set(FileManager.default.subpaths(atPath: source.path)?.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: source.appendingPathComponent($0).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        } ?? [])
        XCTAssertTrue(shippedFiles.contains("manifest.json"))
        for file in shippedFiles {
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(file)), try Data(contentsOf: source.appendingPathComponent(file)), file)
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("manifest.json"))) as! [String: Any]
        var name = try XCTUnwrap(manifest["name"] as? String)
        if name.hasPrefix("__MSG_"), let locale = manifest["default_locale"] as? String {
            let key = String(name.dropFirst("__MSG_".count).dropLast(2))
            let messages = try JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("_locales/\(locale)/messages.json"))) as! [String: Any]
            name = try XCTUnwrap((messages[key] as? [String: Any])?["message"] as? String)
        }
        XCTAssertEqual(name, "MacCode Computer Use")
        // The server refuses an extension older than it needs; the copy MacCode ships must not be.
        let shipped = try XCTUnwrap(manifest["version"] as? String)
        XCTAssertNotEqual(shipped.compare(ChromeProfileConnection.minimumExtensionVersion, options: .numeric), .orderedAscending)
        XCTAssertEqual(ChromeProfileConnection.hostName, "io.remotecode.computer_use")
        let native = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/io.remotecode.computer_use.json")
        let registration = try JSONSerialization.jsonObject(with: Data(contentsOf: native)) as! [String: Any]
        XCTAssertEqual(registration["allowed_origins"] as? [String], ["chrome-extension://ejnjfchbceelacijgldkmckpmjfpdgip/"])
        // The mac-use release's own extension keeps its registration; MacCode never writes it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(ManagedMacUse.chromeHostName).json").path))
        let wrapper = try String(contentsOfFile: XCTUnwrap(registration["path"] as? String))
        XCTAssertTrue(wrapper.contains(executable))
        XCTAssertTrue(wrapper.contains(ChromeProfileConnection.hostArgument))
        XCTAssertTrue(ChromeProfileConnection.isRegistered(homeDirectory: home), "browser_status must not report not_installed after setup")
        XCTAssertTrue(ChromeProfileConnection.socketPath.hasSuffix("/Library/Application Support/RemoteCode/ChromeComputerUse/bridge.sock"))
    }

    func testRegistrationForAnotherExtensionDoesNotCountAsInstalled() throws {
        // WHY: Chrome starts the host only for the origins its registration allows; a file that
        // names another extension can never connect MacCode's, so status must say not_installed.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rc-chrome-reg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let hosts = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        let other = ["name": ChromeProfileConnection.hostName, "allowed_origins": ["chrome-extension://\(String(repeating: "a", count: 32))/"]] as [String: Any]
        try JSONSerialization.data(withJSONObject: other).write(to: hosts.appendingPathComponent("\(ChromeProfileConnection.hostName).json"))
        XCTAssertFalse(ChromeProfileConnection.isRegistered(homeDirectory: home))
    }

    func testHostAdmitsOnlyMacCodesExtensionOrigin() {
        // WHY: the host forwards whatever the caller asks to the user's Chrome profile; only the
        // extension MacCode ships may start it.
        XCTAssertThrowsError(try ChromeProfileConnection.runHost(origin: "chrome-extension://unrelated/"))
        XCTAssertThrowsError(try ChromeProfileConnection.runHost(origin: "chrome-extension://\(String(repeating: "a", count: 32))/"))
    }

    func testNativeFramingRoundTripsUnicodeAndRejectsOversizedFrames() throws {
        // WHY: page text is Unicode, and a frame size from a confused peer must not make the host
        // allocate or wait for a gigabyte.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { Darwin.close($0) } }
        let deadline = Date().addingTimeInterval(2)
        try ChromeProfileConnection.writeFrame(["id": "one", "text": "Olá 👋"], fd: fds[0], until: deadline)
        let read = try ChromeProfileConnection.readFrame(fd: fds[1], until: deadline)
        XCTAssertEqual(read["text"] as? String, "Olá 👋")
        var oversized = UInt32(ChromeProfileConnection.maximumFrameBytes + 1).littleEndian
        _ = withUnsafeBytes(of: &oversized) { Darwin.write(fds[0], $0.baseAddress, 4) }
        XCTAssertThrowsError(try ChromeProfileConnection.readFrame(fd: fds[1], until: deadline))
    }

    func testBrowserToolsReachProfileBackendWithIndependentSessionIdentity() async throws {
        // WHY: each MCP client owns one tab; sharing a session would let one agent act in, or
        // close, another agent's tab.
        let recorder = Requests()
        let first = ChromeProfileComputerUseBackend { try recorder.send($0) }
        let second = ChromeProfileComputerUseBackend { try recorder.send($0) }
        let server = ManagedComputerUseMCP(backend: ComputerUseQueuedPassthroughBackend(), browser: first)
        let line = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_open","arguments":{"url":"https://example.test"}}}"#)
        XCTAssertTrue(try XCTUnwrap(line).contains("current_chrome_profile"))
        _ = await first.invoke(name: "browser_snapshot", arguments: [:])
        _ = await second.invoke(name: "browser_open", arguments: ["url": "https://example.test"])
        XCTAssertEqual(recorder.items.count, 3)
        XCTAssertEqual(recorder.items[0]["session"] as? String, recorder.items[1]["session"] as? String)
        XCTAssertNotEqual(recorder.items[0]["session"] as? String, recorder.items[2]["session"] as? String)
        XCTAssertEqual(recorder.items[0]["operation"] as? String, "browser_open")
        let arguments = try XCTUnwrap(recorder.items[0]["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["url"] as? String, "https://example.test")
    }

    func testHostTellsTheCallerWhenTheExtensionNeverAnswers() throws {
        // The host used to close the caller's socket without a word, which read as a dead
        // bridge and hid that one page had stopped answering.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("b.sock").path
        var toHost: [Int32] = [0, 0], fromHost: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toHost), 0)
        XCTAssertEqual(pipe(&fromHost), 0)
        defer { for fd in toHost + fromHost { close(fd) } }
        let exited = expectation(description: "host exits so Chrome starts a clean one")
        Thread.detachNewThread {
            try? ChromeProfileConnection.runHost(origin: "chrome-extension://\(ChromeProfileConnection.extensionID)/", path: path,
                                                 input: toHost[0], output: fromHost[1], responseTimeout: 0.3)
            exited.fulfill()
        }
        let ready = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: path), Date() < ready { usleep(10_000) }
        let response = try ChromeProfileConnection.request(["operation": "browser_status", "session": "s"], path: path)
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue((response["error"] as? String)?.contains("did not answer") == true, "\(response)")
        wait(for: [exited], timeout: 5)
    }

    func testExtensionStatusNamesEveryStateInsteadOfFailing() throws {
        // An agent that only saw "bridge closed the connection" concluded the extension was not
        // working while Chrome showed it connected. Each state must be told apart, with what to do.
        typealias Failure = ChromeProfileConnection.Failure
        func status(registered: Bool = true, _ send: @escaping ([String: Any], TimeInterval) throws -> [String: Any]) -> [String: Any] {
            ChromeProfileConnection.extensionStatus(registered: registered, send: send)
        }
        let unregistered = status(registered: false) { _, _ in XCTFail("must not ask an extension that is not registered"); return [:] }
        XCTAssertEqual(unregistered["state"] as? String, "not_installed")
        // MacCode sets the extension up from Settings, not from a command line.
        XCTAssertTrue((unregistered["hint"] as? String)?.contains("Settings > Computer Use > Set Up Chrome Extension") == true)

        let closed = status { _, _ in throw Failure(message: "Google Chrome is not running.", kind: .notConnected) }
        XCTAssertEqual(closed["state"] as? String, "not_connected")
        XCTAssertEqual(closed["connected"] as? Bool, false)
        XCTAssertEqual(closed["hint"] as? String, "Google Chrome is not running.")

        // Another client's long call is not a broken extension.
        let busy = status { _, _ in throw Failure(message: "timed out", kind: .timedOut) }
        XCTAssertEqual(busy["state"] as? String, "busy")
        XCTAssertEqual(busy["connected"] as? Bool, true)

        // Files on disk are newer than what Chrome loaded until the extension is reloaded.
        for stale in [["ok": true, "connected": true], ["ok": true, "connected": true, "version": "1.4.1"]] as [[String: Any]] {
            let outdated = status { _, _ in stale }
            XCTAssertEqual(outdated["state"] as? String, "outdated")
            XCTAssertTrue((outdated["hint"] as? String)?.contains("Reload") == true)
        }
        for version in [ChromeProfileConnection.minimumExtensionVersion, "1.10.0"] {
            var asked: TimeInterval = 0
            let current = status { request, timeout in
                asked = timeout
                XCTAssertEqual(request["operation"] as? String, "browser_status")
                return ["id": "x", "ok": true, "connected": true, "hasTab": false, "version": version]
            }
            XCTAssertEqual(current["state"] as? String, "connected", version)
            XCTAssertNil(current["hint"])
            XCTAssertNil(current["id"])
            XCTAssertLessThanOrEqual(asked, 2, "a status question must not wait on a page")
        }
    }

    func testBrowserStatusToolAnswersWithAStateWhenTheBridgeIsDown() async throws {
        let backend = ChromeProfileComputerUseBackend(send: { _ in
            throw ChromeProfileConnection.Failure(message: "The MacCode Chrome extension is not connected.", kind: .notConnected)
        })
        let result = await backend.invoke(name: "browser_status", arguments: [:])
        XCTAssertFalse(result.isError, "status is an answer, not a failure")
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.content.first?.text).utf8)) as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "not_connected")
        // Tools that need the extension still fail, with the same explanation.
        let open = await backend.invoke(name: "browser_open", arguments: ["url": "https://example.com"])
        XCTAssertTrue(open.isError)
        XCTAssertTrue(open.content.first?.text?.contains("not connected") == true)
    }

    func testRequestWaitsOutAnExtensionReconnectButNotAClosedChrome() throws {
        // After any drop the extension reconnects about a second later; a call landing in that
        // gap used to fail and send the agent off to slower routes.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("b.sock").path
        XCTAssertFalse(ChromeProfileConnection.hostListening(path: path))

        let started = Date()
        XCTAssertThrowsError(try ChromeProfileConnection.request(["operation": "browser_status"], path: path, chromeRunning: { false })) {
            XCTAssertTrue($0.localizedDescription.contains("not running"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "nothing to wait for when Chrome is closed")

        Thread.detachNewThread {
            usleep(400_000)
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var address = try? ChromeProfileConnection.address(path) else { return }
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            listen(listener, 1)
            let client = accept(listener, nil, nil)
            if let request = try? ChromeProfileConnection.readFrame(fd: client, until: Date().addingTimeInterval(2)) {
                try? ChromeProfileConnection.writeFrame(["id": request["id"] ?? "", "ok": true, "connected": true], fd: client, until: Date().addingTimeInterval(2))
            }
            close(client)
            close(listener)
        }
        let response = try ChromeProfileConnection.request(["operation": "browser_status"], path: path, chromeRunning: { true })
        XCTAssertEqual(response["connected"] as? Bool, true)
    }

    func testChromeWindowObservationsPointAtTheBrowserToolsOnlyWhenTheyAreUsable() {
        // The agent kept clicking pixels in the Chrome window while a working extension sat idle.
        let chrome: (Int32) -> String? = { $0 == 7 ? "com.google.Chrome" : "com.apple.finder" }
        XCTAssertTrue(ManagedComputerUseMCP.browserToolsHint(pid: 7, bundleID: chrome, extensionConnected: { true })?.contains("browser_open") == true)
        XCTAssertNil(ManagedComputerUseMCP.browserToolsHint(pid: 7, bundleID: chrome, extensionConnected: { false }))
        XCTAssertNil(ManagedComputerUseMCP.browserToolsHint(pid: 8, bundleID: chrome, extensionConnected: { true }))
        XCTAssertNil(ManagedComputerUseMCP.browserToolsHint(pid: nil, bundleID: chrome, extensionConnected: { true }))
    }

    func testATabLeftOpenIsClosedWhenTheClientGoesAway() async {
        // The tab is kept awake by an attached debugger, so one that outlives its agent leaves
        // Chrome's debugging bar on screen until someone finds and closes it.
        final class Calls: @unchecked Sendable { var operations: [String] = [] }
        let calls = Calls()
        let backend = ChromeProfileComputerUseBackend(send: { request in
            calls.operations.append(request["operation"] as? String ?? "")
            return ["ok": true, "closed": true, "released": true]
        })
        let handler = ManagedComputerUseMCP(browser: backend)
        await handler.closeBrowser(extensionConnected: { true })
        XCTAssertEqual(calls.operations, ["browser_close"])
        // With no extension connected there is nothing to close and nothing to wait for.
        await handler.closeBrowser(extensionConnected: { false })
        XCTAssertEqual(calls.operations, ["browser_close"])
    }

    func testEveryBrowserToolThatActsOnThePageAcceptsTheEscalationFlag() throws {
        // A schema with additionalProperties:false that omits the flag would make the client
        // reject the retry the human_activity error asks for.
        for name in ChromeProfileComputerUseBackend.tools where !["browser_status", "browser_open", "browser_close", "browser_dialog"].contains(name) {
            let schema = try XCTUnwrap(ManagedComputerUseMCP.toolCatalog().first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any], name)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], name)
            XCTAssertNotNil(properties["allow_while_user_active"], name)
        }
    }

    func testBrowserMCPRoutesToOwnSessionAndPropagatesFailure() async throws {
        // WHY: human_activity means the user took the tab; the agent must see it as an error.
        let backend = ChromeProfileComputerUseBackend(send: { request in
            let operation = request["operation"] as? String
            if operation == "browser_act" { return ["id": request["id"] ?? "", "ok": false, "error": "human_activity"] }
            return ["ok": true, "connected": true, "operation": operation ?? ""]
        })
        let handler = ManagedComputerUseMCP(browser: backend)
        for (name, arguments, expectedError) in [("browser_status", "{}", false), ("browser_act", #"{"action":"click","ref":"stale"}"#, true)] {
            let line = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\(name)","arguments":\(arguments)}}
            """
            let reply = await handler.handle(line)
            let response = try XCTUnwrap(reply)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let result = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, expectedError)
            XCTAssertTrue(String(describing: result).contains(expectedError ? "human_activity" : "connected"))
        }
    }
    func testExtendedBrowserToolsHaveCatalogMetadataAndMutationClassification() throws {
        let names = ["browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_set_input_files", "browser_download", "page"]
        for name in names {
            XCTAssertTrue(ChromeProfileComputerUseBackend.tools.contains(name), name)
            XCTAssertTrue(ChromeProfileComputerUseBackend.mutationTools.contains(name), name)
            XCTAssertNotNil(ChromeProfileComputerUseBackend.description(for: name), name)
            let schema = try XCTUnwrap(ChromeProfileComputerUseBackend.inputSchema(for: name))
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"] as? [String: Any])
        }
        XCTAssertEqual(Set(ChromeProfileComputerUseBackend.tools).count, ChromeProfileComputerUseBackend.tools.count)
        XCTAssertNil(ChromeProfileComputerUseBackend.inputSchema(for: "unknown"))
        XCTAssertNil(ChromeProfileComputerUseBackend.description(for: "unknown"))
    }

    func testDownloadMovesCompletedFileAndRejectsMissingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-download-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download.txt")
        try Data("download".utf8).write(to: source)
        let backend = ChromeProfileComputerUseBackend(send: { _ in ["ok": true, "download_path": source.path] })
        let result = await backend.invoke(name: "browser_download", arguments: ["ref": "ref", "directory": destination.path])
        XCTAssertFalse(result.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("download.txt")), "download")
        let text = try XCTUnwrap(result.content.first?.text)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(response["path"] as? String, destination.appendingPathComponent("download.txt").path)
        let invalid = await backend.invoke(name: "browser_download", arguments: ["ref": "ref", "directory": root.appendingPathComponent("missing").path])
        XCTAssertTrue(invalid.isError)
    }

    func testDownloadNeverOverwritesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-cu-download-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination.appendingPathComponent("download.txt"))
        let backend = ChromeProfileComputerUseBackend(send: { _ in ["ok": true, "download_path": source.path] })
        let result = await backend.invoke(name: "browser_download", arguments: ["ref": "ref", "directory": destination.path])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: source), "new")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("download.txt")), "old")
    }
}

private final class Requests: @unchecked Sendable {
    let lock = NSLock()
    var items: [[String: Any]] = []
    func send(_ item: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
        return ["ok": true, "mode": "current_chrome_profile"]
    }
}
