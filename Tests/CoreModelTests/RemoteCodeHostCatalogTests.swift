import XCTest
import CoreModel

final class RemoteCodeHostCatalogTests: XCTestCase {
    func test_catalogIsNamedToolsPlusTitioOnlyHostCall() {
        // WHY: named intents stay the default; rc_host_call is the one generic
        // tool, admitted by the host only for Titio.
        let names = RemoteCodeHostCatalog.toolNames
        XCTAssertEqual(names, [
            RemoteCodeHostCatalog.workspaceCreate,
            RemoteCodeHostCatalog.workspaceList,
            RemoteCodeHostCatalog.threadCreate,
            RemoteCodeHostCatalog.threadList,
            RemoteCodeHostCatalog.botCreate,
            RemoteCodeHostCatalog.botList,
            RemoteCodeHostCatalog.botOpen,
            RemoteCodeHostCatalog.botSend,
            RemoteCodeHostCatalog.botThreadCreate,
            RemoteCodeHostCatalog.botSkillCreate,
            RemoteCodeHostCatalog.botSkillView,
            RemoteCodeHostCatalog.activityList,
            RemoteCodeHostCatalog.hostHelp,
            RemoteCodeHostCatalog.hostBatch,
            RemoteCodeHostCatalog.botDelegate,
            RemoteCodeHostCatalog.scheduledTaskRunNext,
            RemoteCodeHostCatalog.browserScreenshot,
            RemoteCodeHostCatalog.chatImage,
            RemoteCodeHostCatalog.genericHostCallTool,
        ])
        XCTAssertFalse(names.contains("rc_host"))
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(RemoteCodeHostCatalog.rpcMethod(for: RemoteCodeHostCatalog.genericHostCallTool), RemoteCodeHostCatalog.hostCallRPC)
        XCTAssertTrue(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.genericHostCallTool), "host.call needs operation_id; admission classifies the actual method")
        XCTAssertEqual(RemoteCodeHostCatalog.rpcMethod(for: RemoteCodeHostCatalog.hostBatch), "host.batch")
        XCTAssertFalse(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.hostHelp))
        XCTAssertEqual(RemoteCodeHostCatalog.rpcMethod(for: RemoteCodeHostCatalog.hostHelp), "host.help")
    }

    func test_mutationsRequireOperationIDAndMapOntoPrivateHostRPC() {
        // WHY: replay uses durable command receipts keyed by client_request_id.
        XCTAssertTrue(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.workspaceCreate))
        XCTAssertTrue(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.botCreate))
        XCTAssertTrue(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.botSkillCreate))
        XCTAssertFalse(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.workspaceList))
        XCTAssertFalse(RemoteCodeHostCatalog.isMutation(RemoteCodeHostCatalog.botSkillView))
        XCTAssertEqual(
            RemoteCodeHostCatalog.rpcMethod(for: RemoteCodeHostCatalog.workspaceCreate),
            "host.workspace.create"
        )
        XCTAssertEqual(
            RemoteCodeHostCatalog.rpcMethod(for: RemoteCodeHostCatalog.botSkillView),
            "host.bot.skill.view"
        )
        for name in RemoteCodeHostCatalog.mutationToolNames {
            let schema = RemoteCodeHostCatalog.schema(for: name)
            XCTAssertEqual(schema["type"] as? String, "object")
            let required = schema["required"] as? [String] ?? []
            XCTAssertTrue(required.contains(RemoteCodeHostCatalog.operationIDKey), name)
        }
    }

    func test_providerDirectiveForbidsComputerUseFallback() {
        let directive = RemoteCodeHostCatalog.providerDirective
        XCTAssertTrue(directive.contains(RemoteCodeHostCatalog.botCreate))
        XCTAssertTrue(directive.contains(RemoteCodeHostCatalog.botSkillView))
        XCTAssertTrue(directive.contains("Computer Use"))
        XCTAssertTrue(directive.contains("macos-harness"))
        XCTAssertTrue(directive.contains("Accessibility"))
        XCTAssertTrue(directive.contains("consulted Bot"))
        XCTAssertTrue(directive.contains("bot_write_home_file"))
        XCTAssertTrue(BotPeerDelegation.providerDirective.contains(directive))
    }

    func test_botCreateDoesNotAcceptProviderOrModel_becauseRouteBelongsToTheCallingThread() throws {
        let schema = RemoteCodeHostCatalog.schema(for: RemoteCodeHostCatalog.botCreate)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNil(properties["provider"])
        XCTAssertNil(properties["model"])
        XCTAssertNotNil(properties["name"])
    }

    func test_bodyDigestIsStableSHA256() {
        let body = "---\nname: qa\n---\nProve this file.\n"
        let digest = RemoteCodeHostCatalog.bodyDigest(body)
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, RemoteCodeHostCatalog.bodyDigest(body))
        XCTAssertNotEqual(digest, RemoteCodeHostCatalog.bodyDigest(body + " "))
    }
}
