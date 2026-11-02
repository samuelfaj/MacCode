import XCTest
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell
@testable import Persistence

/// WHY: a bot screenshot used to reach the iPhone late (on its next reload)
/// and only as a "screenshot.jpg" chip, because the host published no event
/// and had no way to hand out attachment bytes. The phone must learn about the
/// row the moment it is written and be able to fetch a thumbnail and the image
/// itself, while never reading anything outside the host's attachment store,
/// another thread's attachment, or a response large enough to choke the socket.
@MainActor
final class AgentAttachmentGetRemoteTests: XCTestCase {
    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let thread: AgentThread
        let otherThread: AgentThread
        let store: AgentAttachmentStore
        let dispatcher: JSONRPCDispatcher
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [[String: JSONValue]] = []
        func append(_ event: [String: JSONValue]) { lock.withLock { events.append(event) } }
        func appended(thread: AgentThreadID) -> [[String: JSONValue]] {
            lock.withLock {
                events.filter {
                    $0["threadId"]?.objectValue?["value"]?.stringValue?.lowercased()
                        == thread.value.uuidString.lowercased()
                }
            }
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AttachmentGet-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "attachment-get-ws", cwd: workspaceDir.path)
        func thread(_ title: String) throws -> AgentThread {
            try router.createAgentThread(
                workspace: workspace.id, title: title, provider: .codex, model: "fake-model",
                permissionMode: .supervised, reasoningEffort: .medium
            )
        }
        return Fixture(
            ctx: ctx,
            router: router,
            thread: try thread("Screenshot thread"),
            otherThread: try thread("Other thread"),
            store: AgentAttachmentStore(
                root: ctx.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
            ),
            dispatcher: JSONRPCDispatcher(router: router)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A real JPEG of `width` x `height` filled with per-pixel noise so its size is predictable-ish large.
    private func jpeg(width: Int, height: Int, quality: Double = 0.9) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt64.self, capacity: width * height / 2)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(width * height / 2) { pixels[index] = generator.next() }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func get(
        _ f: Fixture,
        thread: AgentThreadID,
        message: AgentMessageID,
        attachmentID: String,
        extra: [String: JSONValue] = [:]
    ) async -> JSONRPCResponse {
        var params: [String: JSONValue] = [
            "thread_id": .string(thread.value.uuidString),
            "message_id": .string(message.value.uuidString),
            "attachment_id": .string(attachmentID),
        ]
        params.merge(extra) { _, new in new }
        return await f.dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "agent.attachment.get", params: params
        ))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func errorKind(_ response: JSONRPCResponse) -> String? {
        response.error?.data?.objectValue?["kind"]?.stringValue
    }

    /// Stages `data` and writes a message carrying it on `thread`.
    private func appendImageMessage(_ f: Fixture, data: Data, thread: AgentThreadID) throws -> (AgentMessage, AgentAttachment) {
        let attachment = try f.store.stage(data: data, displayName: "shot.jpg", kind: .image, mimeType: "image/jpeg")
        let message = AgentMessage(threadId: thread, role: .assistant, content: "📷 shot", attachments: [attachment])
        try f.ctx.messageRepo.append(message)
        return (message, attachment)
    }

    // MARK: - Screenshot event, then the bytes behind it

    /// The phone hears about the screenshot as soon as the row is written, and
    /// the reference in that event is enough to fetch the exact JPEG.
    /// WHY: an agent that rendered images or used Playwright had no way to show
    /// them in the chat and answered with /tmp paths the phone cannot open.
    func test_postChatImages_appendsOneAssistantMessageWithEveryImage() throws {
        let f = try makeFixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-chat-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("maquete.jpg")
        let second = dir.appendingPathComponent("planta.jpg")
        try jpeg(width: 320, height: 200).write(to: first)
        try jpeg(width: 200, height: 320).write(to: second)

        let result = try f.router.postChatImages(callerThread: f.thread.id, paths: [first.path, second.path], caption: "Maquete e planta")

        let stored = try XCTUnwrap(try f.ctx.messageRepo.list(threadId: f.thread.id).last)
        XCTAssertEqual(stored.role, .assistant)
        XCTAssertEqual(stored.content, "Maquete e planta")
        XCTAssertEqual(stored.attachments.map(\.kind), [.image, .image])
        XCTAssertEqual(result.objectValue?["attachment_ids"]?.arrayValue?.count, 2)

        let text = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        XCTAssertThrowsError(try f.router.postChatImages(callerThread: f.thread.id, paths: [text.path], caption: nil),
                             "only images are posted")
        XCTAssertThrowsError(try f.router.postChatImages(callerThread: f.thread.id, paths: [dir.appendingPathComponent("missing.png").path], caption: nil),
                             "a missing file is reported, not posted")
        XCTAssertEqual(try f.ctx.messageRepo.list(threadId: f.thread.id).count, 1, "rejected calls add no message")
    }

    func test_screenshotPosted_publishesAppendedEventWhoseAttachmentIsFetchable() async throws {
        let f = try makeFixture()
        let log = EventLog()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.message.appended", let object = event.payload.objectValue else { return }
            log.append(object)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let shot = try jpeg(width: 320, height: 200)

        NotificationCenter.default.post(name: .botScreenshotPosted, object: nil, userInfo: [
            BotHostNotificationKey.botID: BotID(),
            BotHostNotificationKey.threadID: f.thread.id,
            BotHostNotificationKey.jpeg: shot,
            BotHostNotificationKey.reason: "tela de login",
            BotHostNotificationKey.kind: "login",
        ])
        await waitUntil { !log.appended(thread: f.thread.id).isEmpty }

        let events = log.appended(thread: f.thread.id)
        XCTAssertEqual(events.count, 1, "exactly one appended event for one screenshot")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["role"]?.stringValue, "assistant")
        XCTAssertEqual(event["content"]?.stringValue, "📷 tela de login")
        let stored = try XCTUnwrap(try f.ctx.messageRepo.list(threadId: f.thread.id).last)
        XCTAssertEqual(
            event["id"]?.objectValue?["value"]?.stringValue?.lowercased(),
            stored.id.value.uuidString.lowercased(),
            "the event names the persisted row, so a later reload dedupes it"
        )
        let reference = try XCTUnwrap(event["attachments"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(reference["kind"]?.stringValue, "image")
        XCTAssertEqual(reference["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertNil(reference["path"], "paired devices never see a host path")
        let attachmentID = try XCTUnwrap(reference["id"]?.stringValue)

        let response = await get(f, thread: f.thread.id, message: stored.id, attachmentID: attachmentID)
        XCTAssertNil(response.error)
        let result = try decode(AgentAttachmentGet.Result.self, try XCTUnwrap(response.result))
        XCTAssertEqual(Data(base64Encoded: result.dataBase64), shot)
        XCTAssertFalse(result.thumbnail)
        XCTAssertEqual(result.dataMimeType, "image/jpeg")
        XCTAssertEqual(result.sizeBytes, shot.count)
        XCTAssertEqual(result.dataSizeBytes, shot.count)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 200)
        XCTAssertEqual(result.sha256, SHA256.hash(data: shot).map { String(format: "%02x", $0) }.joined())
    }

    /// The list thumbnail is a small JPEG, not the full screenshot.
    func test_thumbnail_isBoundedJPEGOfTheImage() async throws {
        let f = try makeFixture()
        let original = try jpeg(width: 1600, height: 1000)
        let (message, attachment) = try appendImageMessage(f, data: original, thread: f.thread.id)

        let response = await get(
            f, thread: f.thread.id, message: message.id, attachmentID: try XCTUnwrap(attachment.id),
            extra: ["thumbnail": .bool(true), "thumbnail_max_pixels": .number(256)]
        )
        XCTAssertNil(response.error)
        let result = try decode(AgentAttachmentGet.Result.self, try XCTUnwrap(response.result))
        XCTAssertTrue(result.thumbnail)
        XCTAssertEqual(result.dataMimeType, "image/jpeg")
        XCTAssertEqual(max(result.width ?? 0, result.height ?? 0), 256, "long edge clamps to the asked size")
        XCTAssertEqual(result.width, 256)
        XCTAssertEqual(result.height, 160, "aspect ratio is kept")
        XCTAssertLessThan(result.dataSizeBytes, original.count)
        XCTAssertEqual(result.sizeBytes, original.count, "size_bytes stays the original's")
        let thumbnail = try XCTUnwrap(Data(base64Encoded: result.dataBase64))
        XCTAssertEqual(thumbnail.count, result.dataSizeBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    // MARK: - Size caps

    /// An image over max_bytes is refused with its size so the phone can ask
    /// for a thumbnail instead; the ceiling applies even when the phone asks for more.
    func test_sizeCap_refusesOversizedBytesAndClampsToCeiling() async throws {
        let f = try makeFixture()
        let small = try jpeg(width: 200, height: 200)
        let (message, attachment) = try appendImageMessage(f, data: small, thread: f.thread.id)
        let id = try XCTUnwrap(attachment.id)

        let tight = await get(f, thread: f.thread.id, message: message.id, attachmentID: id,
                              extra: ["max_bytes": .number(Double(small.count - 1))])
        XCTAssertEqual(tight.error?.code, AgentAttachmentGetWire.tooLargeCode)
        XCTAssertEqual(errorKind(tight), "too_large")
        XCTAssertEqual(tight.error?.data?.objectValue?["data_size_bytes"]?.intValue, small.count)
        XCTAssertNil(tight.result)

        let exact = await get(f, thread: f.thread.id, message: message.id, attachmentID: id,
                              extra: ["max_bytes": .number(Double(small.count))])
        XCTAssertNil(exact.error, "a response exactly at max_bytes is allowed")

        // Larger than the 256 KiB ceiling: noisy, near-lossless 1200x1200.
        let big = try jpeg(width: 1200, height: 1200, quality: 1.0)
        XCTAssertGreaterThan(big.count, AgentAttachmentGetWire.maxBytesCeiling)
        let (bigMessage, bigAttachment) = try appendImageMessage(f, data: big, thread: f.thread.id)
        let bigID = try XCTUnwrap(bigAttachment.id)
        let refused = await get(f, thread: f.thread.id, message: bigMessage.id, attachmentID: bigID,
                                extra: ["max_bytes": .number(Double(big.count * 2))])
        XCTAssertEqual(errorKind(refused), "too_large", "the client cannot raise the ceiling")
        XCTAssertEqual(refused.error?.data?.objectValue?["max_bytes"]?.intValue, AgentAttachmentGetWire.maxBytesCeiling)

        let thumbnail = await get(f, thread: f.thread.id, message: bigMessage.id, attachmentID: bigID,
                                  extra: ["thumbnail": .bool(true), "thumbnail_max_pixels": .number(256)])
        XCTAssertNil(thumbnail.error, "the thumbnail is the way to show an image over the cap")
    }

    /// A full-size read whose recorded size is already over the cap is
    /// refused from the reference alone, so it never reads or hashes the blob
    /// (shown here by the blob being gone: the answer is still too_large).
    func test_sizeCap_refusesKnownOversizeBeforeReadingTheBlob() async throws {
        let f = try makeFixture()
        let shot = try jpeg(width: 200, height: 200)
        let (message, attachment) = try appendImageMessage(f, data: shot, thread: f.thread.id)
        try FileManager.default.removeItem(atPath: attachment.path)
        let id = try XCTUnwrap(attachment.id)

        let refused = await get(f, thread: f.thread.id, message: message.id, attachmentID: id,
                                extra: ["max_bytes": .number(Double(shot.count - 1))])
        XCTAssertEqual(errorKind(refused), "too_large")
        XCTAssertEqual(refused.error?.data?.objectValue?["data_size_bytes"]?.intValue, shot.count)

        let fits = await get(f, thread: f.thread.id, message: message.id, attachmentID: id)
        XCTAssertEqual(errorKind(fits), "unavailable", "within the cap the missing blob is still reported honestly")
    }

    /// Thumbnails are fetched in `rpc.batch`; a batched error item carries no
    /// `data`, so the phone must still decode the attachment kind from it.
    func test_batch_errorItemsDecodeToAttachmentKinds() async throws {
        let f = try makeFixture()
        let shot = try jpeg(width: 200, height: 200)
        let (message, attachment) = try appendImageMessage(f, data: shot, thread: f.thread.id)
        let id = try XCTUnwrap(attachment.id)
        func call(_ thread: AgentThreadID, _ extra: [String: JSONValue]) -> JSONValue {
            var params: [String: JSONValue] = [
                "thread_id": .string(thread.value.uuidString),
                "message_id": .string(message.id.value.uuidString),
                "attachment_id": .string(id),
            ]
            params.merge(extra) { _, new in new }
            return .object(["method": .string("agent.attachment.get"), "params": .object(params)])
        }
        let response = await f.dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "rpc.batch", params: ["calls": .array([
                call(f.thread.id, ["thumbnail": .bool(true), "thumbnail_max_pixels": .number(64)]),
                call(f.thread.id, ["max_bytes": .number(Double(shot.count - 1))]),
                call(f.otherThread.id, ["thumbnail": .bool(true)]),
            ])]
        ))
        XCTAssertNil(response.error)
        let items = try XCTUnwrap(response.result?.arrayValue)
        XCTAssertEqual(items.count, 3)

        let thumbnail = try decode(AgentAttachmentGet.Result.self, items[0])
        XCTAssertTrue(thumbnail.thumbnail)

        func treatyKind(_ item: JSONValue) throws -> RemoteCodeError.Kind {
            let error = try XCTUnwrap(item.objectValue?["error"]?.objectValue)
            return RemoteCodeError(
                code: try XCTUnwrap(error["code"]?.intValue),
                message: error["message"]?.stringValue ?? "",
                data: try error["data"].map { try decode(RemoteCodeJSONValue.self, $0) }
            ).kind
        }
        XCTAssertEqual(try treatyKind(items[1]), .attachmentTooLarge)
        XCTAssertEqual(try treatyKind(items[2]), .attachmentNotFound, "another thread's message is not found, even batched")
    }

    // MARK: - Containment

    /// Knowing an attachment id is not enough: the message must be on the
    /// thread asked for, and the attachment must be on that message.
    func test_containment_rejectsOtherThreadAndOtherMessage() async throws {
        let f = try makeFixture()
        let (message, attachment) = try appendImageMessage(f, data: try jpeg(width: 64, height: 64), thread: f.thread.id)
        let (otherMessage, _) = try appendImageMessage(f, data: try jpeg(width: 64, height: 64), thread: f.thread.id)
        let id = try XCTUnwrap(attachment.id)

        let wrongThread = await get(f, thread: f.otherThread.id, message: message.id, attachmentID: id)
        XCTAssertEqual(wrongThread.error?.code, AgentAttachmentGetWire.notFoundCode)
        XCTAssertEqual(wrongThread.error?.data?.objectValue?["missing"]?.stringValue, "message")

        let wrongMessage = await get(f, thread: f.thread.id, message: otherMessage.id, attachmentID: id)
        XCTAssertEqual(errorKind(wrongMessage), "not_found")
        XCTAssertEqual(wrongMessage.error?.data?.objectValue?["missing"]?.stringValue, "attachment")

        let unknownMessage = await get(f, thread: f.thread.id, message: AgentMessageID(), attachmentID: id)
        XCTAssertEqual(errorKind(unknownMessage), "not_found")

        let decoded = RemoteCodeError(code: wrongThread.error?.code ?? 0, message: "", data: try decode(
            RemoteCodeJSONValue.self, try XCTUnwrap(wrongThread.error?.data)
        ))
        XCTAssertEqual(decoded.kind, .attachmentNotFound, "the treaty maps the error the phone receives")
    }

    /// A persisted attachment that points outside the store (directly or via
    /// a symlink planted in the store) is never read, even if its digest matches.
    func test_containment_neverReadsBytesOutsideTheStore() async throws {
        let f = try makeFixture()
        let secret = Data("not an attachment".utf8)
        let digest = SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AttachmentOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let outside = outsideDir.appendingPathComponent(digest)
        try secret.write(to: outside)

        let direct = AgentAttachment(id: UUID().uuidString.lowercased(), path: outside.path, displayName: "x.txt",
                                     kind: .file, mimeType: "text/plain", sha256: digest, sizeBytes: secret.count)
        try FileManager.default.createDirectory(at: f.store.root, withIntermediateDirectories: true)
        let link = f.store.root.appendingPathComponent(digest)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linked = AgentAttachment(id: UUID().uuidString.lowercased(), path: link.path, displayName: "y.txt",
                                     kind: .file, mimeType: "text/plain", sha256: digest, sizeBytes: secret.count)
        let message = AgentMessage(threadId: f.thread.id, role: .user, content: "files", attachments: [direct, linked])
        try f.ctx.messageRepo.append(message)

        for attachment in [direct, linked] {
            let response = await get(f, thread: f.thread.id, message: message.id, attachmentID: try XCTUnwrap(attachment.id))
            XCTAssertEqual(response.error?.code, AgentAttachmentGetWire.unavailableCode, attachment.displayName)
            XCTAssertEqual(response.error?.data?.objectValue?["reason"]?.stringValue, "missing")
            XCTAssertNil(response.result)
        }
    }

    /// Bytes changed on disk after the message was written are not served as
    /// that attachment; a thumbnail of a non-image is refused honestly.
    func test_failure_tamperedBytesAndNonImageThumbnailAreUnavailable() async throws {
        let f = try makeFixture()
        let (message, attachment) = try appendImageMessage(f, data: try jpeg(width: 64, height: 64), thread: f.thread.id)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: attachment.path))
        let tampered = await get(f, thread: f.thread.id, message: message.id, attachmentID: try XCTUnwrap(attachment.id))
        XCTAssertEqual(errorKind(tampered), "unavailable")

        let file = try f.store.stage(data: Data("hello".utf8), displayName: "notes.txt", kind: .file, mimeType: "text/plain")
        let fileMessage = AgentMessage(threadId: f.thread.id, role: .user, content: "notes", attachments: [file])
        try f.ctx.messageRepo.append(fileMessage)
        let fileID = try XCTUnwrap(file.id)
        let thumbnail = await get(f, thread: f.thread.id, message: fileMessage.id, attachmentID: fileID,
                                  extra: ["thumbnail": .bool(true)])
        XCTAssertEqual(thumbnail.error?.data?.objectValue?["reason"]?.stringValue, "not_image")

        let plain = await get(f, thread: f.thread.id, message: fileMessage.id, attachmentID: fileID)
        XCTAssertNil(plain.error, "a file attachment is still readable as bytes")
        let result = try decode(AgentAttachmentGet.Result.self, try XCTUnwrap(plain.result))
        XCTAssertEqual(Data(base64Encoded: result.dataBase64), Data("hello".utf8))
        XCTAssertNil(result.width)
    }

    func test_malformedParamsAreInvalidParamsBeforeAnyLookup() async throws {
        let f = try makeFixture()
        let thread = f.thread.id.value.uuidString
        let message = UUID().uuidString
        let cases: [[String: JSONValue]] = [
            ["message_id": .string(message), "attachment_id": .string("a")],
            ["thread_id": .string(thread), "attachment_id": .string("a")],
            ["thread_id": .string(thread), "message_id": .string(message)],
            ["thread_id": .string(thread), "message_id": .string(message), "attachment_id": .string("  ")],
            ["thread_id": .string(thread), "message_id": .string(message), "attachment_id": .string("a"), "thumbnail": .string("yes")],
            ["thread_id": .string(thread), "message_id": .string(message), "attachment_id": .string("a"), "max_bytes": .number(0)],
            ["thread_id": .string(thread), "message_id": .string(message), "attachment_id": .string("a"), "thumbnail_max_pixels": .string("big")],
        ]
        for params in cases {
            let response = await f.dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1), method: "agent.attachment.get", params: params
            ))
            XCTAssertEqual(response.error?.code, -32602, "\(params.keys.sorted())")
        }
    }

    /// The read runs off the main actor, so a large image cannot stall the Mac UI.
    func test_read_runsMessageLookupOffMainActor() async throws {
        let f = try makeFixture()
        let (message, attachment) = try appendImageMessage(f, data: try jpeg(width: 64, height: 64), thread: f.thread.id)
        AgentAppReadGateway.resetExecutionProbesForTesting()
        defer { AgentAppReadGateway.resetExecutionProbesForTesting() }
        let response = await get(f, thread: f.thread.id, message: message.id, attachmentID: try XCTUnwrap(attachment.id))
        XCTAssertNil(response.error)
        XCTAssertGreaterThanOrEqual(AgentAppReadGateway.readOffMainActorCountForTesting, 1)
        XCTAssertEqual(AgentAppReadGateway.readOnMainActorCountForTesting, 0)
    }
}
