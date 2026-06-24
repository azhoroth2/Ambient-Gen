import SwiftUI

struct ContentView: View {
    @State private var audioEngine = AudioEngine()

    var body: some View {
        ZStack {
            // Minimalist solid black background
            Color.black
                .ignoresSafeArea()

            // Play / Stop button centered
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
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundColor(audioEngine.isPlaying ? .black : .white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Group {
                        if audioEngine.isPlaying {
                            Capsule()
                                .fill(Color.white)
                        } else {
                            Capsule()
                                .strokeBorder(Color.white, lineWidth: 1.5)
                        }
                    }
                )
            }
            .buttonStyle(.plain)
        }
        .frame(width: 400, height: 400)
    }
}

#Preview {
    ContentView()
}
