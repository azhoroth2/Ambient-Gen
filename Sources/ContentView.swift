import SwiftUI

struct ContentView: View {
    @State private var audioEngine = AudioEngine()
    @State private var selectedMode: SoundMode = .relaxation

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

            VStack(spacing: 28) {
                // Title
                VStack(spacing: 4) {
                    Text("🎧")
                        .font(.system(size: 28))

                    Text("AmbientGen")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .white.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }

                // Mode buttons
                HStack(spacing: 16) {
                    ForEach(SoundMode.allCases) { mode in
                        ModeCard(
                            mode: mode,
                            isSelected: selectedMode == mode,
                            isPlaying: audioEngine.isPlaying
                        ) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                selectedMode = mode
                                audioEngine.setMode(mode)
                            }
                        }
                    }
                }

                // Play / Stop button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        audioEngine.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: audioEngine.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))

                        Text(audioEngine.isPlaying ? "Stop" : "Play")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
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
                        radius: 12, y: 4
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(32)
        }
        .frame(width: 420, height: 340)
        .onAppear {
            audioEngine.setMode(selectedMode)
        }
    }
}

// MARK: - Mode Card

struct ModeCard: View {
    let mode: SoundMode
    let isSelected: Bool
    let isPlaying: Bool
    let action: () -> Void

    private var accentHue: Double {
        mode == .relaxation ? 0.55 : 0.12
    }

    private var glowColor: Color {
        Color(hue: accentHue, saturation: 0.7, brightness: 0.7)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Text(mode.icon)
                    .font(.system(size: 32))
                    .shadow(color: isSelected ? glowColor.opacity(0.6) : .clear, radius: 8)

                Text(mode.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text(mode.subtitle)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                Text(mode.frequencyLabel)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                isSelected
                                    ? Color(hue: accentHue, saturation: 0.4, brightness: 0.2).opacity(0.5)
                                    : Color.clear
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? glowColor.opacity(0.6)
                                    : Color.white.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
            .shadow(
                color: isSelected ? glowColor.opacity(0.3) : .clear,
                radius: isSelected ? 16 : 0,
                y: isSelected ? 4 : 0
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
