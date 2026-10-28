import Foundation
import XCTest
import CoreModel
import AgentRuntime
@testable import AppShell

final class BotContextGuestRecoveryTests: XCTestCase {
    private struct Fixture {
        let support: URL
        let identity: BotContextRuntimeIdentity
        let runID = AgentRunID()

        init() throws {
            support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            identity = try BotContextRuntimeIdentity(hostID: "host", botID: BotID(), context: .general, policyRevision: 1)
        }

        var scope: URL {
            support.appendingPathComponent("guest-runs", isDirectory: true)
                .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
        }

        func recordURL(_ id: AgentRunID? = nil) -> URL {
            scope.appendingPathComponent("\((id ?? runID).value.uuidString.lowercased()).context.json")
        }

        func writeRecord(_ id: AgentRunID? = nil, state: String = "pending") throws {
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(BotContextGuestRecovery.Record(
                version: 1, hostID: identity.hostID, botID: identity.botID,
                context: identity.context, policyRevision: identity.policyRevision,
                runID: id ?? runID, state: state == "ended" ? .ended : .pending
            ))
            try data.write(to: recordURL(id))
        }

        func assertState(_ state: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let data = try Data(contentsOf: recordURL())
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["state"] as? String, state, file: file, line: line)
        }
    }

    func testPendingRunRefusesSecondFreshRun() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        try BotContextGuestRecovery.begin(identity: f.identity, runID: f.runID, appSupport: f.support)
        XCTAssertThrowsError(try BotContextGuestRecovery.begin(identity: f.identity, runID: AgentRunID(), appSupport: f.support))
        try f.assertState("pending")
    }

    func testLiveSiblingRunOnSameVMDoesNotBlockSecondRun() throws {
        // WHY: two conversations of one bot share its VM. A live sibling's
        // pending record and env file are not crash residue; anything else is.
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        try BotContextGuestRecovery.begin(identity: f.identity, runID: f.runID, appSupport: f.support)
        try Data("environment".utf8).write(to: f.scope.appendingPathComponent("\(f.runID.value.uuidString.lowercased()).env"))
        XCTAssertNoThrow(try BotContextGuestRecovery.begin(identity: f.identity, runID: AgentRunID(),
            appSupport: f.support, liveRunIDs: [f.runID]))
        XCTAssertThrowsError(try BotContextGuestRecovery.begin(identity: f.identity, runID: AgentRunID(),
            appSupport: f.support, liveRunIDs: []), "a pending record nobody owns stays uncertain")
    }

    func testEndedRunRefusesSameUUIDAndAllowsDifferentUUID() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        try BotContextGuestRecovery.begin(identity: f.identity, runID: f.runID, appSupport: f.support)
        try BotContextGuestRecovery.end(identity: f.identity, runID: f.runID, appSupport: f.support)
        try f.assertState("ended")
        XCTAssertThrowsError(try BotContextGuestRecovery.begin(identity: f.identity, runID: f.runID, appSupport: f.support))
        XCTAssertNoThrow(try BotContextGuestRecovery.begin(identity: f.identity, runID: AgentRunID(), appSupport: f.support))
    }

    func testCompletedSharedRunDoesNotStopAReusedVMOnRecovery() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        let identity = try BotContextRuntimeIdentity(hostID: "host", botID: BotID(),
            context: .general, policyRevision: 1, virtualMachineID: UUID())
        try BotContextGuestRecovery.begin(identity: identity, runID: f.runID, appSupport: f.support)
        try BotContextGuestRecovery.end(identity: identity, runID: f.runID, appSupport: f.support)
        let report = BotContextGuestRecovery.reconcile(docker: nil, appSupport: f.support)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.reconciled, [identity.storageBotID.value.uuidString.lowercased()])
    }

    func testReconcileWithoutDockerRetainsPendingRecordAndMatchingEnvironment() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        try f.writeRecord()
        let env = f.scope.appendingPathComponent("\(f.runID.value.uuidString.lowercased()).env")
        try Data("environment".utf8).write(to: env)
        let report = BotContextGuestRecovery.reconcile(docker: nil, appSupport: f.support)
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.recordURL().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.path))
        try f.assertState("pending")
    }

    func testMalformedRecordAndSymlinkReportFailureWithoutTouchingSentinel() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        try FileManager.default.createDirectory(at: f.scope, withIntermediateDirectories: true)
        let malformed = f.recordURL()
        try Data("{not-json".utf8).write(to: malformed)
        let report1 = BotContextGuestRecovery.reconcile(docker: nil, appSupport: f.support)
        XCTAssertFalse(report1.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: malformed), Data("{not-json".utf8))

        try FileManager.default.removeItem(at: malformed)
        let sentinel = f.support.appendingPathComponent("external-sentinel")
        let sentinelData = Data("keep me".utf8)
        try sentinelData.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: malformed, withDestinationURL: sentinel)
        let report2 = BotContextGuestRecovery.reconcile(docker: nil, appSupport: f.support)
        XCTAssertFalse(report2.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    }

    func testEnvironmentWithoutRecordIsUncertainAndBlocksNewPreparation() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        try FileManager.default.createDirectory(at: f.scope, withIntermediateDirectories: true)
        let env = f.scope.appendingPathComponent("\(f.runID.value.uuidString.lowercased()).env")
        try Data("synthetic residue".utf8).write(to: env)
        let report = BotContextGuestRecovery.reconcile(docker: nil, appSupport: f.support)
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertTrue(report.reconciled.isEmpty)
        XCTAssertThrowsError(try BotContextGuestRecovery.begin(identity: f.identity, runID: AgentRunID(), appSupport: f.support))
        XCTAssertEqual(try Data(contentsOf: env), Data("synthetic residue".utf8))
    }

    func testDirectoryDurabilityFailureIsReported() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        let directory = try PrivateDirectory(f.support, create: false)
        directory.close()
        XCTAssertThrowsError(try directory.synchronize())
    }

    func testMissingRunsDirectoryIsCompleteAndEmpty() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.support) }
        let report = BotContextGuestRecovery.reconcile(docker: nil, appSupport: f.support)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.reconciled.isEmpty)
    }
}
