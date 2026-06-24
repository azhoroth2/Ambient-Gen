import SwiftUI

struct ContentView: View {
    @State private var audioEngine = AudioEngine()

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(hue: 0.72, saturation: 0.35, brightness: 0.12),
                    Color(hue: 0.75, saturation: 0.45, brightness: 0.08),
                    Color(hue: 0.80, saturation: 0.30, brightness: 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Play / Stop button in the absolute geometric center
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    audioEngine.toggle()
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: audioEngine.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))

                    Text(audioEngine.isPlaying ? "Stop" : "Play")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 48)
                .padding(.vertical, 18)
                .background(
                    Capsule()
                        .fill(
                            audioEngine.isPlaying
                                ? AnyShapeStyle(Color(hue: 0.0, saturation: 0.5, brightness: 0.45))
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            Color(hue: 0.55, saturation: 0.6, brightness: 0.5),
                                            Color(hue: 0.6, saturation: 0.7, brightness: 0.4)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                )
                .shadow(
                    color: audioEngine.isPlaying
                        ? Color.red.opacity(0.2)
                        : Color.cyan.opacity(0.25),
                    radius: 18, y: 6
                )
            }
            .buttonStyle(.plain)
        }
        .frame(width: 240, height: 160)
    }
}

#Preview {
    ContentView()
}
