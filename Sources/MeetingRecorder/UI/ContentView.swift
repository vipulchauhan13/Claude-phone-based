import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if !permissions.allGranted {
                permissionsSection
                Divider()
            }
            sourcesSection
            optionsSection
            Divider()
            controls
            if !session.statusMessage.isEmpty {
                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = session.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.settings.transcribe, !session.transcript.segments.isEmpty {
                Divider()
                TranscriptView(store: session.transcript)
            }
        }
        .padding(16)
        .frame(width: 360)
        .task {
            permissions.refresh()
            await session.refreshDevices()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(session.isRecording ? .red : .secondary)
                .font(.title2)
            Text("Meeting Recorder").font(.headline)
            Spacer()
            if case .recording(let since) = session.state {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(TranscriptStore.timestamp(context.date.timeIntervalSince(since)))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.subheadline.bold())
            permissionRow("Screen Recording (video + system audio)", permissions.screenRecording, permissions.openScreenRecordingSettings)
            permissionRow("Microphone", permissions.microphone, permissions.openMicrophoneSettings)
            permissionRow("Speech Recognition (transcript)", permissions.speechRecognition, permissions.openSpeechSettings)
            HStack {
                Button("Request permissions") { Task { await permissions.requestAll() } }
                Text("Screen Recording takes effect after relaunching the app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ title: String, _ state: Permissions.State, _ openSettings: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state == .granted ? .green : .secondary)
            Text(title).font(.caption)
            Spacer()
            if state != .granted {
                Button("Settings…", action: openSettings).controlSize(.small)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Display", selection: $session.selectedDisplayID) {
                ForEach(session.displays, id: \.displayID) { display in
                    Text("Display \(display.displayID) (\(display.width)×\(display.height))")
                        .tag(Optional(display.displayID))
                }
            }
            Picker("Microphone", selection: $session.selectedMicrophoneID) {
                ForEach(session.microphones, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(Optional(device.uniqueID))
                }
            }
            .disabled(!session.settings.captureMicrophone)
        }
        .disabled(session.isRecording || session.isBusy)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Record what others say (system audio)", isOn: $session.settings.captureSystemAudio)
            Toggle("Record what I say (microphone)", isOn: $session.settings.captureMicrophone)
            Toggle("Live transcript (on-device)", isOn: $session.settings.transcribe)
            Toggle("Allow Apple cloud transcription if on-device is unavailable", isOn: $session.settings.allowCloudTranscription)
                .disabled(!session.settings.transcribe)
                .font(.caption)
            Toggle("Retina resolution (larger files)", isOn: $session.settings.retinaResolution)
            Toggle("Also save a single-track mixed copy", isOn: $session.settings.createMixedCopy)
            HStack {
                Picker("Codec", selection: $session.settings.codec) {
                    ForEach(RecordingWriter.VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("FPS", selection: $session.settings.frameRate) {
                    ForEach([15, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(session.isRecording || session.isBusy)
    }

    private var controls: some View {
        HStack {
            if session.isRecording {
                Button(role: .destructive) {
                    Task { await session.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    session.dismissError()
                    Task { await session.start() }
                } label: {
                    Label(session.isBusy ? "Working…" : "Start recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.isBusy)
                .keyboardShortcut("r", modifiers: .command)
            }
            if let url = session.lastRecordingURL, !session.isRecording {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal the last recording in Finder")
            }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
            .disabled(session.isRecording)
        }
        .controlSize(.large)
    }
}

struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.segments) { segment in
                        HStack(alignment: .top, spacing: 6) {
                            Text(TranscriptStore.timestamp(segment.start))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(segment.speaker + ":")
                                .bold()
                                .foregroundStyle(segment.speaker == "You" ? .blue : .orange)
                            Text(segment.text)
                                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                        }
                        .font(.caption)
                        .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .onChange(of: store.segments.count) { _ in
                if let last = store.segments.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
