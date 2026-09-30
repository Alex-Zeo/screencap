import AppKit
import ScreenCaptureKit

private final class NullOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

/// Screen recording to MP4 using SCRecordingOutput (macOS 15+), which handles encoding and muxing.
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private let sink = NullOutput()
    private var outputURL: URL?

    var onFinish: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    var isRecording: Bool { stream != nil }

    /// `sourceRect` is in the display's local top-left-origin points; nil records the whole display.
    func start(screen: NSScreen, sourceRect: CGRect?, to url: URL) async throws {
        let content = try await CaptureService.content()
        guard let id = CaptureService.displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == me },
                                     exceptingWindows: [])
        let region = sourceRect ?? CGRect(origin: .zero, size: screen.frame.size)
        let config = SCStreamConfiguration()
        if sourceRect != nil { config.sourceRect = region }
        // H.264 needs even dimensions.
        config.width = Int(region.width * screen.backingScaleFactor) & ~1
        config.height = Int(region.height * screen.backingScaleFactor) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recConfig, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        self.outputURL = url
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() } catch { onError?(error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            if let url = self.outputURL { self.onFinish?(url) }
            self.outputURL = nil
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.onError?(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.onError?(error)
        }
    }
}
