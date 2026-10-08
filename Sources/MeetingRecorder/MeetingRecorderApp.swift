import SwiftUI

/// A menu-bar-only app: click the record icon in the menu bar to open the control panel.
@main
struct MeetingRecorderApp: App {
    @StateObject private var session = RecordingSession()
    @StateObject private var permissions = Permissions()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(session)
                .environmentObject(permissions)
        } label: {
            Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
