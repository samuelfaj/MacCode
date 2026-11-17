import Foundation
import ScreenCaptureKit

@available(macOS 15.0, *)
final class TrajectoryVideo: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let lock = NSLock()
    private var finished = false
    private var failure: String?

    func start(url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "video_unavailable", code: 1) }
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        self.stream = stream
        try await stream.startCapture()
    }

    private func status() -> (Bool, String?) {
        lock.lock(); defer { lock.unlock() }
        return (finished, failure)
    }

    func stop() async throws {
        try await stream?.stopCapture()
        for _ in 0..<100 {
            let (done, error) = status()
            if let error { throw NSError(domain: error, code: 1) }
            if done { stream = nil; return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "video_finalize_timeout", code: 1)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); failure = error.localizedDescription; finished = true; lock.unlock()
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); finished = true; lock.unlock()
    }
}
