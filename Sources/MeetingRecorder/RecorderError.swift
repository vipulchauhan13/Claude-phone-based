import Foundation

enum RecorderError: LocalizedError {
    case noDisplay
    case noMicrophone
    case cannotConfigureMicrophone
    case nothingRecorded
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display is available to record."
        case .noMicrophone: return "No microphone was found."
        case .cannotConfigureMicrophone: return "The microphone could not be added to the capture session."
        case .nothingRecorded: return "No audio or video frames were captured, so no file was written."
        case .exportFailed: return "Creating the mixed-audio copy failed."
        }
    }
}
