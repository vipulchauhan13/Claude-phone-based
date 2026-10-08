import AVFoundation
import CoreMedia

/// Captures the user's own voice from a microphone with AVCaptureSession.
///
/// AVCaptureAudioDataOutput hands us CMSampleBuffers directly, which is exactly what
/// AVAssetWriter and the transcriber consume, so no manual format juggling is needed.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Called on a background queue. Timestamps are already converted to the host clock.
    var onSample: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "MeetingRecorder.microphone", qos: .userInitiated)
    private var output: AVCaptureAudioDataOutput?

    static func availableMicrophones() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
    }

    func start(device requestedDevice: AVCaptureDevice?) throws {
        guard let device = requestedDevice ?? AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noMicrophone
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError.cannotConfigureMicrophone }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecorderError.cannotConfigureMicrophone }
        session.addOutput(output)
        self.output = output

        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        output = nil
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // AVCaptureSession stamps buffers with its own synchronization clock. ScreenCaptureKit uses the
        // host clock, so convert here; then every track in the file lines up without guesswork.
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var buffer = sampleBuffer
        if let sessionClock = session.synchronizationClock {
            let hostTime = CMSyncConvertTime(presentationTime, from: sessionClock, to: CMClockGetHostTimeClock())
            if hostTime != presentationTime {
                buffer = SampleBufferTiming.retimed(sampleBuffer, to: hostTime)
            }
        }
        onSample?(buffer)
    }
}
