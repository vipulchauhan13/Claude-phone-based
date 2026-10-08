import Foundation

struct RecordingSettings {
    var captureSystemAudio = true
    var captureMicrophone = true
    var transcribe = true
    var allowCloudTranscription = false
    var frameRate = 30
    var retinaResolution = false
    var codec: RecordingWriter.VideoCodec = .h264
    var createMixedCopy = true
    var locale: Locale = .current
    var outputDirectory: URL = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("MeetingRecorder", isDirectory: true)
}
