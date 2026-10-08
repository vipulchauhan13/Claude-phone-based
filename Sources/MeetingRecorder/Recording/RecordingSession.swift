import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Coordinates the capture engines, the file writer, and the transcribers for one recording.
///
/// Data flow while recording (every arrow is a CMSampleBuffer on a background queue):
///
///   ScreenCaptureEngine ──video──────────▶ RecordingWriter (video track)
///                       ──system audio──▶ RecordingWriter (audio track 1) + Transcriber("Others")
///   MicrophoneCapture   ──mic audio─────▶ RecordingWriter (audio track 2) + Transcriber("You")
///
@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording(since: Date)
        case finishing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var settings = RecordingSettings()
    @Published private(set) var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var statusMessage = ""

    let transcript = TranscriptStore()

    private let screen = ScreenCaptureEngine()
    private let microphone = MicrophoneCapture()
    private var writer: RecordingWriter?
    private var microphoneTranscriber: Transcriber?
    private var systemTranscriber: Transcriber?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .finishing: return true
        default: return false
        }
    }

    // MARK: Device discovery

    func refreshDevices() async {
        do {
            displays = try await ScreenCaptureEngine.availableDisplays()
            if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = displays.first?.displayID
            }
        } catch {
            statusMessage = "Cannot list displays: \(error.localizedDescription). Grant Screen Recording permission and relaunch."
        }

        microphones = MicrophoneCapture.availableMicrophones()
        if selectedMicrophoneID == nil || !microphones.contains(where: { $0.uniqueID == selectedMicrophoneID }) {
            selectedMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID
        }
    }

    // MARK: Start / stop

    func start() async {
        guard state == .idle || isFailed else { return }
        state = .preparing
        statusMessage = ""
        transcript.reset()

        do {
            if displays.isEmpty { await refreshDevices() }
            guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) ?? displays.first else {
                throw RecorderError.noDisplay
            }

            let scale = settings.retinaResolution ? 2 : 1
            let videoSize = CGSize(width: display.width * scale, height: display.height * scale)
            let startTime = SampleBufferTiming.hostTimeNow()
            let url = try makeOutputURL()

            let writer = try RecordingWriter(url: url, configuration: .init(
                videoSize: videoSize,
                frameRate: settings.frameRate,
                codec: settings.codec,
                includeSystemAudio: settings.captureSystemAudio,
                includeMicrophone: settings.captureMicrophone,
                startTime: startTime
            ))
            try writer.start()
            self.writer = writer

            configureTranscribers(startTime: startTime)
            wireCallbacks(writer: writer)

            if settings.captureMicrophone {
                let device = microphones.first { $0.uniqueID == selectedMicrophoneID }
                try microphone.start(device: device)
            }
            try await screen.start(display: display, configuration: .init(
                frameRate: settings.frameRate,
                scale: scale,
                captureSystemAudio: settings.captureSystemAudio
            ))

            lastRecordingURL = url
            state = .recording(since: Date())
        } catch {
            await tearDown(cancelWriter: true)
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard isRecording, let writer else { return }
        state = .finishing

        await screen.stop()
        microphone.stop()
        await microphoneTranscriber?.finish()
        await systemTranscriber?.finish()

        do {
            try await writer.finish()
            let url = writer.url
            lastRecordingURL = url
            if writer.droppedSamples > 0 {
                statusMessage = "Saved. \(writer.droppedSamples) frames were dropped because the encoder fell behind."
            } else {
                statusMessage = "Saved to \(url.lastPathComponent)"
            }

            if settings.transcribe, !transcript.segments.isEmpty {
                let transcriptURL = url.deletingPathExtension().appendingPathExtension("transcript.md")
                try transcript.write(to: transcriptURL, title: url.deletingPathExtension().lastPathComponent)
            }

            if settings.createMixedCopy, settings.captureSystemAudio, settings.captureMicrophone {
                let mixedURL = url.deletingPathExtension().appendingPathExtension("mixed.mp4")
                try await Mixdown.exportMixed(from: url, to: mixedURL)
            }
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
        await tearDown(cancelWriter: false)
    }

    func dismissError() {
        if isFailed { state = .idle }
    }

    // MARK: - Private

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func makeOutputURL() throws -> URL {
        try FileManager.default.createDirectory(at: settings.outputDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return settings.outputDirectory.appendingPathComponent("Meeting \(formatter.string(from: Date())).mp4")
    }

    private func configureTranscribers(startTime: CMTime) {
        microphoneTranscriber = nil
        systemTranscriber = nil
        guard settings.transcribe else { return }

        let configuration = Transcriber.Configuration(locale: settings.locale, allowCloudRecognition: settings.allowCloudTranscription)
        let transcript = self.transcript
        let handler: (TranscriptSegment) -> Void = { segment in
            Task { @MainActor in transcript.upsert(segment) }
        }

        if settings.captureMicrophone {
            let transcriber = Transcriber(speaker: "You", recordingStart: startTime, configuration: configuration)
            transcriber.onSegment = handler
            microphoneTranscriber = transcriber
        }
        if settings.captureSystemAudio {
            let transcriber = Transcriber(speaker: "Others", recordingStart: startTime, configuration: configuration)
            transcriber.onSegment = handler
            systemTranscriber = transcriber
        }

        let anyTranscriber = microphoneTranscriber ?? systemTranscriber
        if let anyTranscriber, !anyTranscriber.isAvailable {
            statusMessage = "Transcription is off: on-device speech recognition is not available for \(settings.locale.identifier) and cloud recognition is disabled."
        }
    }

    private func wireCallbacks(writer: RecordingWriter) {
        let micTranscriber = microphoneTranscriber
        let sysTranscriber = systemTranscriber

        screen.onSample = { output in
            switch output {
            case .video(let buffer):
                writer.append(buffer, to: .video)
            case .systemAudio(let buffer):
                writer.append(buffer, to: .systemAudio)
                sysTranscriber?.append(buffer)
            }
        }
        microphone.onSample = { buffer in
            writer.append(buffer, to: .microphone)
            micTranscriber?.append(buffer)
        }
        screen.onStop = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.statusMessage = "Screen capture stopped: \(error.localizedDescription)"
                await self.stop()
            }
        }
    }

    private func tearDown(cancelWriter: Bool) async {
        screen.onSample = nil
        screen.onStop = nil
        microphone.onSample = nil
        await screen.stop()
        microphone.stop()
        if cancelWriter { writer?.cancel() }
        writer = nil
        microphoneTranscriber = nil
        systemTranscriber = nil
    }
}
