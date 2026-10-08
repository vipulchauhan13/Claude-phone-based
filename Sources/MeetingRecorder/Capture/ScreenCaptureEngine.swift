import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures a display's video frames and, optionally, all system audio using ScreenCaptureKit.
///
/// System audio capture (what other people say in a Teams/Zoom/Meet call, plus any other app)
/// has been available through ScreenCaptureKit since macOS 13. Before that, the only option
/// was a virtual audio driver such as BlackHole; this engine needs no kernel extension.
final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Output {
        case video(CMSampleBuffer)
        case systemAudio(CMSampleBuffer)
    }

    /// Called on a background queue for every captured frame or audio buffer.
    var onSample: ((Output) -> Void)?
    /// Called on a background queue if the stream stops on its own (display unplugged, permission revoked, ...).
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "MeetingRecorder.screen.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "MeetingRecorder.screen.audio", qos: .userInitiated)

    /// Lists the displays that can be recorded. The first call triggers the Screen Recording permission prompt.
    static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    struct Configuration {
        var frameRate: Int = 30
        /// 1 = capture at the display's point size, 2 = Retina-resolution capture (4x the pixels).
        var scale: Int = 1
        var captureSystemAudio: Bool = true
        var showsCursor: Bool = true
    }

    func start(display: SCDisplay, configuration: Configuration) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width * configuration.scale
        config.height = display.height * configuration.scale
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = configuration.showsCursor
        config.queueDepth = 5

        // System audio. Excluding our own process keeps any UI sounds we make out of the recording.
        config.capturesAudio = configuration.captureSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit also delivers "idle" and "incomplete" frames; only complete ones are worth encoding.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRawValue = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete
            else { return }
            onSample?(.video(sampleBuffer))

        case .audio:
            onSample?(.systemAudio(sampleBuffer))

        @unknown default:
            // macOS 15 adds `.microphone`; this app captures the microphone itself so it works on macOS 13+.
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
