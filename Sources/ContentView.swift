import SwiftUI

struct ContentView: View {
    @State private var audioEngine = AudioEngine()

    var body: some View {
        ZStack {
            // Minimalist solid black background
            Color.black
                .ignoresSafeArea()

            // Sound-Reactive Pixel Wave & Chladni Sand Pattern Visualizer
            TimelineView(.animation) { timelineContext in
                let time = timelineContext.date.timeIntervalSinceReferenceDate
                let level = audioEngine.currentLevel
                let activeVoices = audioEngine.activeVoices

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let maxRadius = max(size.width, size.height) * 0.70
                    
                    // Pixel grid configuration
                    let pixelSize: CGFloat = 8.0
                    let gap: CGFloat = 4.0
                    let cellSize = pixelSize + gap
                    
                    // Wave propagation speed (for background ripples)
                    let speed = 4.0
                    let wavePhaseOffset = time * speed
                    
                    // Calculate active melody envelope sum
                    let activeMelodyEnv = activeVoices.map { $0.envelopeValue }.reduce(0.0, +)
                    let melodyActivity = min(1.0, activeMelodyEnv)
                    
                    // Calculate grid offset to center the pixels perfectly
                    let cols = Int(size.width / cellSize)
                    let rows = Int(size.height / cellSize)
                    let startX = (size.width - CGFloat(cols) * cellSize) / 2 + cellSize / 2
                    let startY = (size.height - CGFloat(rows) * cellSize) / 2 + cellSize / 2
                    
                    let levelScale = level * 3.5 // Reactivity boost
                    
                    for c in 0..<cols {
                        for r in 0..<rows {
                            let x = startX + CGFloat(c) * cellSize
                            let y = startY + CGFloat(r) * cellSize
                            
                            let dx = x - center.x
                            let dy = y - center.y
                            let distance = sqrt(dx*dx + dy*dy)
                            
                            // Normalized progress (0...1) from center
                            let progress = distance / maxRadius
                            let edgeFade = max(0.0, 1.0 - progress)
                            
                            // Normalized coordinates for Chladni math (-1...1 inside maxRadius)
                            let u = dx / maxRadius
                            let v = dy / maxRadius
                            
                            // 1. Calculate circular concentric ripple (default resting state)
                            let ripplePhase = distance * 0.035 - wavePhaseOffset
                            let circularRipple = 0.5 + 0.5 * sin(ripplePhase)
                            
                            // 2. Calculate Chladni sand shape pattern (when melody plays)
                            var chladniVal = 0.0
                            var activeWeight = 0.0
                            
                            // Physical vibration shimmer effect on coordinates (simulates plate vibration)
                            let shimmerAmt = 0.022 * melodyActivity
                            let vu = u + sin(time * 35.0 + distance * 0.1) * shimmerAmt
                            let vv = v + cos(time * 35.0 + distance * 0.1) * shimmerAmt
                            
                            for voice in activeVoices {
                                let env = voice.envelopeValue
                                if env > 0.01 {
                                    let (n, m) = getChladniModes(frequency: voice.frequency)
                                    // Chladni square plate resonance formula:
                                    // cos(n * pi * x) * cos(m * pi * y) - cos(m * pi * x) * cos(n * pi * y)
                                    let val = cos(n * Double.pi * vu) * cos(m * Double.pi * vv) -
                                              cos(m * Double.pi * vu) * cos(n * Double.pi * vv)
                                    chladniVal += val * env
                                    activeWeight += env
                                }
                            }
                            
                            if activeWeight > 0 {
                                chladniVal = chladniVal / activeWeight
                            }
                            
                            // Nodal lines are where amplitude is near 0 (sand accumulates at plate nodes)
                            let chladniNodal = max(0.0, 1.0 - abs(chladniVal) * 3.8)
                            
                            // 3. Blend between circular ripples and Chladni sand shapes based on melody activity
                            let finalIntensity = (1.0 - melodyActivity) * circularRipple + melodyActivity * chladniNodal
                            
                            // Wave intensity scales dramatically with sound
                            let waveIntensity = finalIntensity * (0.15 + levelScale * 1.6)
                            
                            // Pixel scale: scales up on active wave parts
                            let scale = 0.5 + finalIntensity * 0.5 * (1.0 + levelScale * 0.4)
                            let currentPixelSize = pixelSize * scale
                            
                            // Opacity: background pixels are dim, wave is bright
                            let opacity = (0.04 + waveIntensity * 0.75) * edgeFade
                            
                            if opacity < 0.01 { continue }
                            
                            // Draw glow layer for active wave pixels (boxShadow emulation)
                            if waveIntensity > 0.18 {
                                let glowSize = currentPixelSize * 2.0
                                let glowRect = CGRect(
                                    x: x - glowSize / 2,
                                    y: y - glowSize / 2,
                                    width: glowSize,
                                    height: glowSize
                                )
                                context.fill(
                                    Path(glowRect),
                                    with: .color(.white.opacity(0.14 * waveIntensity * edgeFade))
                                )
                            }
                            
                            // Draw the solid pixel
                            let rect = CGRect(
                                x: x - currentPixelSize / 2,
                                y: y - currentPixelSize / 2,
                                width: currentPixelSize,
                                height: currentPixelSize
                            )
                            
                            context.fill(
                                Path(rect),
                                with: .color(.white.opacity(opacity))
                            )
                        }
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
                                 .background(Capsule().fill(Color.black)) // prevent showing pixel grid lines under transparent button text
                         }
                     }
                 )
             }
            .buttonStyle(.plain)
        }
        .frame(width: 400, height: 400)
    }

    /// Determines Chladni plate vibration modes based on the active melody frequency.
    private func getChladniModes(frequency: Double) -> (n: Double, m: Double) {
        if frequency <= 0 { return (2, 2) }
        // Map frequencies to specific Chladni resonances
        // Low octaves/frequencies get simpler shapes, high ones get more complex grids
        if frequency < 100 {
            return (2.0, 3.0)
        } else if frequency < 140 { // C3 range (~130 Hz)
            return (3.0, 2.0)
        } else if frequency < 155 { // D3 range (~146 Hz)
            return (4.0, 2.0)
        } else if frequency < 180 { // E3 range (~165 Hz)
            return (3.0, 5.0)
        } else if frequency < 210 { // G3 range (~196 Hz)
            return (5.0, 4.0)
        } else if frequency < 250 { // A3 range (~220 Hz)
            return (6.0, 2.0)
        } else if frequency < 350 { // Octave up notes
            return (5.0, 5.0)
        } else {
            return (7.0, 3.0)
        }
    }
}

#Preview {
    ContentView()
}
