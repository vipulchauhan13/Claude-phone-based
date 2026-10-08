import AVFoundation
import CoreMedia
import Speech

/// Streams one audio source (microphone *or* system audio) into Apple's Speech framework.
///
/// One instance is created per source, each with its own speaker label, which is how the
/// transcript separates "You" from "Others" without any speaker-diarization model.
///
/// Recognition requests are restarted every ~50 s: server-based recognition is capped at
/// one minute per request, and even on-device recognition stays more accurate on shorter runs.
final class Transcriber {
    struct Configuration {
        var locale: Locale = .current
        /// When false and on-device recognition is unavailable, transcription is silently disabled
        /// instead of sending meeting audio to Apple's servers.
        var allowCloudRecognition = false
        var restartInterval: TimeInterval = 50
    }

    let speaker: String
    /// Called on an arbitrary queue with partial and final results.
    var onSegment: ((TranscriptSegment) -> Void)?

    private let configuration: Configuration
    private let recognizer: SFSpeechRecognizer?
    private let recordingStart: CMTime
    private let queue = DispatchQueue(label: "MeetingRecorder.transcriber", qos: .utility)
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cycleStarted = Date.distantPast
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Nil when the chosen locale is unsupported or the privacy setting forbids cloud recognition.
    private(set) var isAvailable: Bool
    private(set) var usesOnDeviceRecognition: Bool

    init(speaker: String, recordingStart: CMTime, configuration: Configuration) {
        self.speaker = speaker
        self.recordingStart = recordingStart
        self.configuration = configuration

        let recognizer = SFSpeechRecognizer(locale: configuration.locale)
        self.recognizer = recognizer
        let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
        usesOnDeviceRecognition = onDevice
        isAvailable = (recognizer?.isAvailable ?? false) && (onDevice || configuration.allowCloudRecognition)
    }

    /// Thread-safe; call from the capture queue that owns the buffers.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isAvailable else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let elapsed = CMTimeSubtract(presentationTime, recordingStart).seconds
        guard elapsed >= 0, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        queue.async { [self] in
            if request == nil || Date().timeIntervalSince(cycleStarted) > configuration.restartInterval {
                startCycle(at: elapsed)
            }
            guard let request, let converted = convert(pcm) else { return }
            request.append(converted)
        }
    }

    /// Stops feeding audio and waits (bounded) for the final recognition result.
    func finish() async {
        let pendingTask: SFSpeechRecognitionTask? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                request?.endAudio()
                request = nil
                continuation.resume(returning: task)
            }
        }
        guard let pendingTask else { return }
        let deadline = Date().addingTimeInterval(5)
        while pendingTask.state != .completed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Private

    private func startCycle(at elapsed: TimeInterval) {
        guard let recognizer else { return }
        request?.endAudio() // the previous task delivers its final result on its own

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = usesOnDeviceRecognition
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let segmentID = UUID()
        let speaker = self.speaker
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.onSegment?(TranscriptSegment(
                id: segmentID,
                speaker: speaker,
                start: elapsed,
                text: result.bestTranscription.formattedString,
                isFinal: result.isFinal
            ))
        }

        self.request = request
        self.task = task
        cycleStarted = Date()
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            converterInputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Wraps the PCM payload of a CMSampleBuffer in an AVAudioPCMBuffer without copying twice.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
