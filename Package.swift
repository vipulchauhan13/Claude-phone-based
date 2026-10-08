// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [
        // ScreenCaptureKit system-audio capture and SwiftUI MenuBarExtra both need macOS 13.
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            path: "Sources/MeetingRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
