import AVFoundation
import CoreMedia

/// Writes one MP4 containing a video track plus up to two separate audio tracks:
/// the system audio (other participants) and the microphone (the user).
///
/// Keeping the two audio sources on separate tracks is what makes "who said what"
/// possible later: each track is transcribed on its own and labelled accordingly.
final class RecordingWriter {
    enum Track: Hashable {
        case video
        case systemAudio
        case microphone
    }

    enum VideoCodec: String, CaseIterable, Identifiable {
        case h264 = "H.264"
        case hevc = "HEVC"

        var id: String { rawValue }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            }
        }
    }

    struct Configuration {
        var videoSize: CGSize
        var frameRate: Int
        var codec: VideoCodec
        var includeSystemAudio: Bool
        var includeMicrophone: Bool
        /// All samples are written relative to this host-clock time. Samples older than it are dropped.
        var startTime: CMTime
    }

    let url: URL
    private let writer: AVAssetWriter
    private var inputs: [Track: AVAssetWriterInput] = [:]
    private let queue = DispatchQueue(label: "MeetingRecorder.writer", qos: .userInitiated)
    private let startTime: CMTime
    private var appendedSamples = 0
    private(set) var droppedSamples = 0

    init(url: URL, configuration: Configuration) throws {
        self.url = url
        self.startTime = configuration.startTime
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let pixels = Int(configuration.videoSize.width * configuration.videoSize.height)
        // ~0.1 bit per pixel per frame is a comfortable quality for screen content.
        let bitrate = max(2_000_000, pixels * configuration.frameRate / 10)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: configuration.codec.avCodec,
            AVVideoWidthKey: Int(configuration.videoSize.width),
            AVVideoHeightKey: Int(configuration.videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
            ],
        ]
        add(AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings), as: .video)

        if configuration.includeSystemAudio {
            add(AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2)), as: .systemAudio)
        }
        if configuration.includeMicrophone {
            add(AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1)), as: .microphone)
        }
    }

    private func add(_ input: AVAssetWriterInput, as track: Track) {
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        inputs[track] = input
    }

    private static func aacSettings(channels: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ]
    }

    func start() throws {
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.nothingRecorded
        }
        writer.startSession(atSourceTime: startTime)
    }

    /// Thread-safe; may be called from any capture queue.
    func append(_ sampleBuffer: CMSampleBuffer, to track: Track) {
        queue.async { [self] in
            guard writer.status == .writing, let input = inputs[track] else { return }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentationTime >= startTime else { return } // arrived before the session started

            guard input.isReadyForMoreMediaData else {
                droppedSamples += 1 // the encoder is behind; dropping is better than stalling the capture queue
                return
            }
            if input.append(sampleBuffer) {
                appendedSamples += 1
            } else {
                droppedSamples += 1
            }
        }
    }

    /// Finalises the file. Throws if nothing was written or the writer failed.
    func finish() async throws {
        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard writer.status == .writing else {
                    continuation.resume(returning: .failure(writer.error ?? RecorderError.nothingRecorded))
                    return
                }
                guard appendedSamples > 0 else {
                    writer.cancelWriting()
                    continuation.resume(returning: .failure(RecorderError.nothingRecorded))
                    return
                }
                inputs.values.forEach { $0.markAsFinished() }
                writer.finishWriting { [self] in
                    if let error = writer.error {
                        continuation.resume(returning: .failure(error))
                    } else {
                        continuation.resume(returning: .success(()))
                    }
                }
            }
        }
        try outcome.get()
    }

    func cancel() {
        queue.async { [self] in
            if writer.status == .writing { writer.cancelWriting() }
        }
    }
}
