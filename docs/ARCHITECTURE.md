# Architecture

## Data flow

```
                     ┌──────────────────────┐
 Display ──────────▶ │ ScreenCaptureEngine  │──video (BGRA frames)──────────┐
 System audio ─────▶ │ (ScreenCaptureKit)   │──system audio (48 kHz st.)──┐ │
                     └──────────────────────┘                             │ │
                                                                          ▼ ▼
                     ┌──────────────────────┐                     ┌──────────────────┐
 Microphone ───────▶ │ MicrophoneCapture    │──mic audio──────────▶│ RecordingWriter  │──▶ Meeting.mp4
                     │ (AVCaptureSession)   │                      │ (AVAssetWriter)  │     video + 2 audio tracks
                     └──────────────────────┘                      └──────────────────┘
                              │                        │
                              ▼                        ▼
                     Transcriber("You")        Transcriber("Others")
                     (SFSpeechRecognizer)      (SFSpeechRecognizer)
                              └──────────┬─────────────┘
                                         ▼
                                  TranscriptStore ──▶ Meeting.transcript.md
                                                      (also shown live in the UI)

 After stop:  Meeting.mp4 ──AVMutableComposition + AVAssetExportSession──▶ Meeting.mixed.mp4
```

Every arrow carries `CMSampleBuffer`s on a background `DispatchQueue`. `RecordingSession`
(a `@MainActor` object) only wires the closures and flips UI state; it never touches a buffer.

## Why ScreenCaptureKit for system audio

Before macOS 13 there was no public API to capture the audio the Mac plays. Apps relied on a
virtual audio device (BlackHole, Soundflower, Loopback) that the user had to install and route.
ScreenCaptureKit's `SCStreamConfiguration.capturesAudio` delivers a clean 48 kHz stereo float
stream of everything on the default output, excluding our own process. That stream is exactly
the remote side of a call.

macOS 15 added microphone capture to ScreenCaptureKit as well (`captureMicrophone`). This app
keeps using `AVCaptureSession` for the microphone so it runs on macOS 13 and 14 too; switching
would delete `MicrophoneCapture.swift` and add one output type to the stream.

## Keeping three streams in sync

`AVAssetWriter` writes samples using their presentation timestamps, so all tracks must share a
clock.

- ScreenCaptureKit stamps buffers with the **host clock** (`CMClockGetHostTimeClock`).
- `AVCaptureSession` stamps buffers with its own `synchronizationClock`. `MicrophoneCapture`
  converts each timestamp with `CMSyncConvertTime` to the host clock before handing it on.
- `RecordingSession` reads the host clock once right before starting capture and passes it to
  the writer as `startSession(atSourceTime:)`. Any buffer stamped earlier than that is dropped.
  The video may begin a few frames late, which players render as a short black lead-in.

## Writer details

- One `AVAssetWriterInput` per track with `expectsMediaDataInRealTime = true`.
- Appends happen on a serial queue. If an input is not ready, the sample is dropped and counted
  rather than blocking the capture queue; ScreenCaptureKit stalls if its callback blocks.
- The audio inputs specify AAC with an explicit `AVChannelLayoutKey`, which lets AVFoundation
  convert the incoming float PCM (any sample rate, mono or stereo) without extra code.
- `finish()` fails with `nothingRecorded` instead of writing an empty, broken file when no
  samples ever arrived (usually a permissions problem).

## Transcription

- One `Transcriber` per audio source, each with a speaker label. This is what turns two audio
  tracks into "You:" and "Others:" lines without diarization.
- Audio is converted to 16 kHz mono float with `AVAudioConverter` before being appended, which
  keeps CPU low and is a format the recognizer handles well.
- `requiresOnDeviceRecognition` is set whenever the recognizer supports it. If it does not (the
  language model for that locale is not installed) and `allowCloudTranscription` is off, the
  transcriber reports itself unavailable rather than uploading meeting audio.
- A new recognition request starts every 50 s. Server recognition is capped at about a minute per
  request, and shorter requests keep partial results snappy. Each request produces one transcript
  segment keyed by a UUID, so partial results update in place.
- Segment timestamps are the recording-relative time of the first buffer in the request, computed
  from the buffer's host-clock timestamp minus the recording start, so they match the video.

## Permissions

| Permission | Triggered by | Where the user fixes it |
|---|---|---|
| Screen Recording | first `SCShareableContent` call, or `CGRequestScreenCaptureAccess()` | Privacy & Security > Screen Recording, then relaunch |
| Microphone | `AVCaptureDevice.requestAccess(for: .audio)` | Privacy & Security > Microphone |
| Speech Recognition | `SFSpeechRecognizer.requestAuthorization` | Privacy & Security > Speech Recognition |

macOS keys all three to the bundle identifier and code signature, which is why
`scripts/build-app.sh` produces a signed `.app` instead of relying on `swift run`.

## Threading model

| Object | Isolation |
|---|---|
| `RecordingSession`, `Permissions`, `TranscriptStore` | `@MainActor` (drive SwiftUI) |
| `ScreenCaptureEngine` callbacks | its own video/audio queues |
| `MicrophoneCapture` callbacks | its own queue |
| `RecordingWriter.append` | serial writer queue |
| `Transcriber.append` | serial transcriber queue; recognizer callbacks hop to the main actor via `Task { @MainActor in }` |
