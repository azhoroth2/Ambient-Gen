import SwiftUI

struct ContentView: View {
    var audioEngine: AudioEngine
    var widgetManager: WidgetWindowManager

    var body: some View {
        @Bindable var engine = audioEngine
        VStack(spacing: 0) {
            VisualizerView(
                audioEngine: audioEngine,
                showPipButton: true,
                isPipActive: widgetManager.isWidgetActive,
                onPipToggle: {
                    widgetManager.toggleWidget(with: audioEngine)
                }
            )
            .frame(maxHeight: .infinity)

            // Divider between visualization and mixer
            Divider()
                .background(Color.white.opacity(0.12))

            // Always-available Mixer Panel
            VStack(spacing: 16) {
                
                // Global Controls
                VStack(spacing: 12) {
                    MixerSlider(label: "Master Volume", value: $engine.globalVolume)
                    TempoSlider(bpm: $engine.bpm)
                }
                
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.horizontal, 8)
                
                // Channel Controls
                VStack(spacing: 12) {
                    MixerSlider(label: "Binaural Beats", value: $engine.oscVolume)
                    MixerSlider(label: "Pink Noise", value: $engine.noiseVolume)
                    MixerSlider(label: "Ambient Synth", value: $engine.melodyVolume)
                    MixerSlider(label: "Lo-Fi Bass", value: $engine.bassVolume)
                    MixerSlider(label: "Lo-Fi Drums", value: $engine.drumsVolume)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(white: 0.05))
        }
        .frame(width: 400, height: 680)
        .background(WindowAccessor { window in
            window.isOpaque = false
            window.backgroundColor = .clear
            window.styleMask = [.borderless]
            window.hasShadow = true
            window.invalidateShadow()
        })
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Helper to access and customize the underlying macOS window hosting the SwiftUI view
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
                
                Task { @MainActor in
                    // Initial smooth fade-in
                    window.alphaValue = 0.0
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.22
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().alphaValue = 1.0
                    }
                }
                
                // Observe key focus transitions for subsequent opens
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        window.alphaValue = 0.0
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.22
                            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                            window.animator().alphaValue = 1.0
                        }
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct MixerSlider: View {
    let label: String
    @Binding var value: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            
            Slider(value: $value, in: 0...1)
                .tint(.white)
        }
    }
}

struct TempoSlider: View {
    @Binding var bpm: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tempo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text("\(Int(bpm)) BPM")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            
            Slider(value: $bpm, in: 50...200, step: 1)
                .tint(.white)
        }
    }
}

#Preview {
    ContentView(audioEngine: AudioEngine(), widgetManager: WidgetWindowManager())
}
