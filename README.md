# Meeting Recorder for macOS

A native macOS menu-bar app that records your screen **and** a meeting's audio from both sides:
what you say (microphone) and what everyone else says (system audio from Teams, Zoom, Meet,
Webex, FaceTime, or any other app), with a live transcript that labels who spoke.

It is written in Swift and uses only Apple frameworks. No virtual audio driver, no kernel
extension, no third-party dependencies.

## Is this doable? Yes, and here is why

Everything the app needs ships with macOS 13 (Ventura) and later:

| Need | Apple framework | Notes |
|---|---|---|
| Screen video | **ScreenCaptureKit** (`SCStream`) | Hardware-accelerated capture of a display, window, or app at up to 60 fps. |
| What *others* say | **ScreenCaptureKit** system audio (`capturesAudio = true`) | Captures all audio the Mac is playing, which includes the remote side of any call. This is the piece that used to require BlackHole or Soundflower. |
| What *you* say | **AVFoundation** (`AVCaptureSession` + microphone) | Same API every camera/mic app uses. |
| Writing one file | **AVFoundation** (`AVAssetWriter`) | Encodes H.264/HEVC video plus two AAC audio tracks into an MP4 in real time. |
| Transcript | **Speech** (`SFSpeechRecognizer`) | On-device recognition, so the audio never leaves the Mac. One recognizer per audio source gives "You" vs "Others" for free. |
| Menu-bar UI | **SwiftUI** (`MenuBarExtra`) | Small control panel with start/stop, device pickers, and the live transcript. |

The only real complexity is plumbing: three concurrent streams of sample buffers on
background queues, one shared clock so the tracks stay in sync, and the three privacy
permissions macOS enforces. This repository contains that plumbing.

## What the app produces

For every recording, in `~/Movies/MeetingRecorder/`:

- `Meeting <date>.mp4`: video + **two separate audio tracks** (track 1: others, track 2: you).
  Keeping the sources apart is what makes speaker attribution possible.
- `Meeting <date>.mixed.mp4`: same video with one mixed audio track, for sharing. Many players
  only play the first audio track of a file, so this is the copy to send around.
- `Meeting <date>.transcript.md`: time-stamped lines like `[00:04:12] Others: Can you share the deck?`

## Project layout

```
Package.swift                              Swift Package (macOS 13+, no dependencies)
Sources/MeetingRecorder/
  MeetingRecorderApp.swift                 @main, MenuBarExtra scene
  Capture/ScreenCaptureEngine.swift        ScreenCaptureKit: display video + system audio
  Capture/MicrophoneCapture.swift          AVCaptureSession microphone, re-timed to the host clock
  Capture/SampleBufferTiming.swift         helper to re-stamp CMSampleBuffers
  Recording/RecordingWriter.swift          AVAssetWriter with 1 video + 2 audio tracks
  Recording/Mixdown.swift                  exports the single-track mixed copy
  Recording/RecordingSession.swift         coordinator: start/stop, wiring, file naming
  Recording/RecordingSettings.swift        user options
  Transcription/Transcriber.swift          SFSpeechRecognizer streaming per audio source
  Transcription/TranscriptStore.swift      merged, time-ordered transcript
  Permissions/Permissions.swift            Screen Recording / Microphone / Speech status + prompts
  UI/ContentView.swift                     control panel + live transcript
Resources/Info.plist                       bundle id, usage descriptions, LSUIElement
Resources/MeetingRecorder.entitlements     audio-input entitlement for hardened runtime
scripts/build-app.sh                       builds and signs build/MeetingRecorder.app
docs/ARCHITECTURE.md                       data flow, clock sync, and design decisions
```

## Build and run

Requirements: a Mac on macOS 13 or newer, Xcode 15 or newer (for the Swift 5.9 toolchain and SDK).

```bash
git clone https://github.com/vipulchauhan13/Claude-phone-based.git
cd Claude-phone-based
git checkout apple-screen-recorder
scripts/build-app.sh --open
```

The script runs `swift build -c release`, assembles `build/MeetingRecorder.app` around the
binary with the `Info.plist`, and ad-hoc signs it. A bundle is required: macOS ties privacy
permissions to a bundle identifier and signature, and refuses microphone access to a binary
without `NSMicrophoneUsageDescription`.

To work in Xcode instead, open `Package.swift` in Xcode. Running from Xcode works for
development, but use the script for a proper bundle when testing permissions.

### First launch

1. Click the record icon in the menu bar and press **Request permissions**.
2. Approve Microphone and Speech Recognition in the prompts.
3. For Screen Recording, macOS shows a prompt once; after approving, **quit and relaunch the app**
   (this is a macOS rule, not an app bug). The panel has a "Settings…" button that opens the
   right pane if you need to flip it manually.
4. Choose the display and microphone, then press **Start recording** (⌘R). **Stop** is ⌘. .

## Important caveats

**Consent and policy.** Recording calls is subject to two-party-consent laws in many places
(several US states, Germany, and others) and almost always to company policy. Tell participants
you are recording. Nothing here hides the fact that a recording is in progress; macOS also shows
the purple screen-recording indicator in the menu bar.

**Speaker attribution is two-way, not per person.** The transcript knows "You" versus "Others"
because they come from different audio sources. Separating several remote participants from each
other needs a speaker-diarization model (for example WhisperKit + pyannote), which is a sensible
next step once the capture pipeline works.

**This code has not been compiled yet.** It was written on a Linux machine without a Swift
toolchain. The APIs are the current, documented ones, but expect to fix a handful of compiler
complaints on the first `swift build`. Report what the compiler says and they are quick to resolve.

**Resource use.** Retina capture of a 5K display at 60 fps is a lot of pixels. The defaults
(display point size, 30 fps, H.264) are comfortable on any Apple-silicon Mac during a call.

**Distribution.** For your own Mac, ad-hoc signing is enough. To hand the app to colleagues you
need a Developer ID certificate, hardened runtime, and notarization (`CODESIGN_IDENTITY=...
scripts/build-app.sh`, then `notarytool`). The Mac App Store additionally requires the App
Sandbox; the entitlements file explains what changes.

## Alternatives considered

- **Electron / Tauri with a native module**: possible, but ScreenCaptureKit system audio and the
  Speech framework still have to be reached from Swift or Objective-C, so the web layer only adds
  weight. Worth it only if you need the same app on Windows.
- **OBS or QuickTime + BlackHole**: works today with no code, but BlackHole is a kernel-level
  audio driver, there is no transcript, and routing audio by hand during a meeting is fragile.
- **The meeting platform's own recording**: Teams/Zoom record server-side and need the organizer's
  permission; this app records locally regardless of who organized the call.

## Roadmap ideas

- Window or single-app capture instead of a whole display (one line in `SCContentFilter`).
- Per-participant diarization with WhisperKit + a diarization model.
- Detect when Teams/Zoom/Meet starts a call and offer to record (`NSWorkspace` app launch
  notifications, or CoreAudio "is any app using the mic" queries).
- Pause/resume, keyboard shortcut from any app, and a Dock-less global hotkey.
- Summaries of the transcript with an LLM after the meeting.
