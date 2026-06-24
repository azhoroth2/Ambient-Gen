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
                            
                            // Slow organic warp LFO to bend the lines gently over time
                            let warpTime = time * 0.5
                            let wu = vu + sin(vv * Double.pi * 1.5 + warpTime) * 0.03 * melodyActivity
                            let wv = vv + cos(vu * Double.pi * 1.5 + warpTime) * 0.03 * melodyActivity
                            
                            for voice in activeVoices {
                                let env = voice.envelopeValue
                                if env > 0.01 {
                                    let (n, m, style) = getChladniParameters(frequency: voice.frequency)
                                    
                                    // Slow time-based LFO to drift the modes slightly (adds fluid organic morphing)
                                    let nMod = n + sin(time * 0.4) * 0.12
                                    let mMod = m + cos(time * 0.3) * 0.12
                                    
                                    let val: Double
                                    switch style {
                                    case 0:
                                        val = cos(nMod * Double.pi * wu) * cos(mMod * Double.pi * wv) -
                                              cos(mMod * Double.pi * wu) * cos(nMod * Double.pi * wv)
                                    case 1:
                                        val = cos(nMod * Double.pi * wu) * cos(mMod * Double.pi * wv) +
                                              cos(mMod * Double.pi * wu) * cos(nMod * Double.pi * wv)
                                    case 2:
                                        val = sin(nMod * Double.pi * wu) * sin(mMod * Double.pi * wv) -
                                              sin(mMod * Double.pi * wu) * sin(nMod * Double.pi * wv)
                                    default:
                                        val = cos(nMod * Double.pi * wu) * sin(mMod * Double.pi * wv) -
                                              sin(mMod * Double.pi * wu) * cos(nMod * Double.pi * wv)
                                    }
                                    
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

             // Play / Stop button in the absolute geometric center (square, no text)
             Button(action: {
                 withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                     audioEngine.toggle()
                 }
             }) {
                 Image(systemName: audioEngine.isPlaying ? "stop.fill" : "play.fill")
                     .font(.system(size: 16, weight: .bold))
                     .contentTransition(.symbolEffect(.replace))
                     .foregroundColor(audioEngine.isPlaying ? .black : .white)
                     .frame(width: 48, height: 48)
                     .background(
                         Group {
                             if audioEngine.isPlaying {
                                 Rectangle()
                                     .fill(Color.white)
                             } else {
                                 Rectangle()
                                     .strokeBorder(Color.white, lineWidth: 1.5)
                                     .background(Rectangle().fill(Color.black)) // prevent showing pixel grid lines under transparent button
                             }
                         }
                     )
             }
             .buttonStyle(.plain)
        }
        .frame(width: 400, height: 400)
    }

    /// Determines Chladni plate vibration modes and formula style procedurally based on active melody frequency.
    private func getChladniParameters(frequency: Double) -> (n: Double, m: Double, style: Int) {
        if frequency <= 0 { return (2.0, 3.0, 0) }
        
        // Deterministic procedural hash from the frequency
        let freqInt = Int(frequency * 100.0)
        
        let n = 2.0 + Double(freqInt % 6)       // n is in 2...7
        let m = 2.0 + Double((freqInt / 7) % 6)  // m is in 2...7
        let style = (freqInt / 13) % 4          // style is in 0...3
        
        // Ensure n and m are not equal to avoid trivial 0 flatlines
        let finalN = n
        var finalM = m
        if finalN == finalM {
            finalM += 1.0
        }
        
        return (finalN, finalM, style)
    }
}

#Preview {
    ContentView()
}
