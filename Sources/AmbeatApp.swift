import SwiftUI

@main
struct AmbeatApp: App {
    @State private var audioEngine = AudioEngine()

    init() {
        // Run as an accessory app (menu bar utility, hides Dock icon)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Load the custom menu bar icon from resources
    private var menuBarIcon: NSImage? {
        guard let url = Bundle.module.url(forResource: "Icon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true // Ensures it adapts to light/dark menu bar modes
        return image
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(audioEngine: audioEngine)
        } label: {
            if let image = menuBarIcon {
                Image(nsImage: image)
            } else {
                Image(systemName: "headphones")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
