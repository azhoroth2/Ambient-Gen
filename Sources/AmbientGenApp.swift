import SwiftUI

@main
struct AmbientGenApp: App {

    init() {
        // When running as a Swift Package executable (no .app bundle),
        // we need to manually promote the process to a regular GUI app
        // so that windows appear and the app shows in the Dock.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 420, height: 340)
        .windowResizability(.contentSize)
    }
}
