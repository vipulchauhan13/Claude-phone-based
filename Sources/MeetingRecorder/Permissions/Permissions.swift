import AVFoundation
import AppKit
import CoreGraphics
import Speech

/// Tracks the three macOS privacy permissions this app needs.
///
/// - Screen Recording: required by ScreenCaptureKit for both video *and* system audio.
///   macOS only prompts once; if the user declines they must enable it in
///   System Settings > Privacy & Security > Screen Recording and relaunch the app.
/// - Microphone: required to capture what the user says.
/// - Speech Recognition: required for the live transcript (Speech framework).
@MainActor
final class Permissions: ObservableObject {
    enum State: Equatable { case granted, denied, notDetermined }

    @Published private(set) var screenRecording: State = .notDetermined
    @Published private(set) var microphone: State = .notDetermined
    @Published private(set) var speechRecognition: State = .notDetermined

    var allGranted: Bool {
        screenRecording == .granted && microphone == .granted
    }

    init() {
        refresh()
    }

    func refresh() {
        // There is no "denied" signal for screen capture; preflight just says yes or no.
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .notDetermined
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechRecognition = .granted
        case .denied, .restricted: speechRecognition = .denied
        case .notDetermined: speechRecognition = .notDetermined
        @unknown default: speechRecognition = .notDetermined
        }
    }

    /// Triggers the system prompts for every permission that has not been decided yet.
    func requestAll() async {
        if !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt the first time. Later calls only return the current value;
            // the user then has to flip the switch in System Settings.
            _ = CGRequestScreenCaptureAccess()
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }

        refresh()
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openSpeechSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
