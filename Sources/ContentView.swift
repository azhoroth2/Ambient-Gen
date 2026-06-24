import SwiftUI

struct ContentView: View {
    @State private var audioEngine = AudioEngine()

    var body: some View {
        ZStack {
            // Minimalist solid black background
            Color.black
                .ignoresSafeArea()

            // Concentric animated waves visualizer
            TimelineView(.animation) { timelineContext in
                let time = timelineContext.date.timeIntervalSinceReferenceDate
                let level = audioEngine.currentLevel

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let maxRadius = max(size.width, size.height) * 0.75
                    
                    // Wave properties - static ring radii to prevent visual snapping
                    let spacing: Double = 16.0
                    let numRings = Int(maxRadius / spacing)
                    
                    // Sound-modulated propagation wave phase
                    // We keep propagation speed constant to avoid phase jumps, but modulate wave intensity by sound
                    let speed = 3.5
                    let wavePhaseOffset = time * speed
                    
                    for r in 1...numRings {
                        let radius = Double(r) * spacing
                        if radius < 15 { continue }
                        
                        // Normalized radius progress (0...1)
                        let progress = radius / maxRadius
                        
                        // Wave intensity based on sine ripple propagating outward
                        let ripplePhase = radius * 0.04 - wavePhaseOffset
                        let ripple = 0.5 + 0.5 * sin(ripplePhase) // 0...1 osc
                        
                        // Modulate width and opacity by audio level and the wave ripple
                        let levelScale = level * 2.5 // Boost level impact
                        
                        // Ripple height is boosted significantly by audio level
                        let waveIntensity = ripple * (0.2 + levelScale * 1.8)
                        
                        // Bold minimalist line width
                        let strokeWidth = 1.0 + waveIntensity * 6.0
                        
                        // Fading opacity: closer to edges fades out, boosted by wave intensity and level
                        let edgeFade = 1.0 - progress
                        let opacity = (0.04 + waveIntensity * 0.45) * edgeFade
                        
                        // Segmented dash pattern mimicking CodePen grid subdivisions
                        // Since radius is static, dashCount is perfectly stable (no snapping)
                        let dashCount = 4 + Int(radius / 24) * 4
                        let perimeter = 2.0 * Double.pi * radius
                        let dashLength = perimeter / Double(dashCount * 2)
                        
                        // Staggered rotation: outer rings rotate slower, giving a spiral effect
                        let rotation = time * 0.12 * (1.0 - progress)
                        
                        // Copy context to isolate transformations per ring
                        var ringContext = context
                        ringContext.opacity = opacity
                        
                        // Rotate ring around center
                        ringContext.translateBy(x: center.x, y: center.y)
                        ringContext.rotate(by: Angle(radians: rotation))
                        ringContext.translateBy(x: -center.x, y: -center.y)
                        
                        var path = Path()
                        path.addEllipse(in: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        ))
                        
                        ringContext.stroke(
                            path,
                            with: .color(.white),
                            style: StrokeStyle(
                                lineWidth: strokeWidth,
                                lineCap: .round,
                                dash: [dashLength, dashLength]
                            )
                        )
                    }
                }
            }
            .ignoresSafeArea()

            // Play / Stop button in the absolute geometric center (size remains same)
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
