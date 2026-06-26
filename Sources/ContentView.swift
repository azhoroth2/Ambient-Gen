import SwiftUI
import ObjectiveC

struct ContentView: View {
    @State private var audioEngine = AudioEngine()
    @State private var isHoveringClose = false
    @State private var hostingWindow: NSWindow?

    var body: some View {
        @Bindable var engine = audioEngine
        VStack(spacing: 0) {
            // Sound-Reactive Pixel Wave & Chladni Sand Pattern Visualizer
            ZStack {
                Color.black
                
                TimelineView(.animation) { timelineContext in
                    let time = timelineContext.date.timeIntervalSinceReferenceDate
                    let level = audioEngine.currentLevel
                    let activeVoices = audioEngine.activeVoices
                    let kickLevel = audioEngine.kickLevel
                    let snareLevel = audioEngine.snareLevel
                    let hatLevel = audioEngine.hatLevel

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
                                
                                // 2. Calculate Chladni sand shape pattern (when melody or drums play)
                                var chladniVal = 0.0
                                var activeWeight = 0.0
                                
                                // Plate activity combines melody activity and drum hits
                                let totalActivity = min(1.0, melodyActivity + kickLevel * 0.8 + snareLevel * 0.8)
                                
                                // Kick creates a deep low-frequency plate/camera shake
                                let kickShake = kickLevel * 0.03 * sin(time * 75.0)
                                
                                // Snare/Hat create high-frequency plate jitter
                                let highJitter = (snareLevel * 0.045 + hatLevel * 0.018) * sin(time * 110.0)
                                
                                // Apply physical vibration shimmer, shake, and jitter to coordinates
                                let shimmerAmt = 0.02 * melodyActivity + highJitter
                                let vu = u + kickShake + sin(time * 35.0 + distance * 0.1) * shimmerAmt
                                let vv = v + kickShake + cos(time * 35.0 + distance * 0.1) * shimmerAmt
                                
                                // Slow organic warp LFO to bend the lines gently over time, modulated by activity
                                let warpTime = time * 0.5
                                let wu = vu + sin(vv * Double.pi * 1.5 + warpTime) * 0.03 * totalActivity
                                let wv = vv + cos(vu * Double.pi * 1.5 + warpTime) * 0.03 * totalActivity
                                
                                // Accumulate melody voices
                                for voice in activeVoices {
                                    let env = voice.envelopeValue
                                    if env > 0.01 {
                                        let (n, m, style) = getChladniParameters(frequency: voice.frequency)
                                        let val = calculateChladni(u: wu, v: wv, n: n, m: m, style: style, time: time)
                                        chladniVal += val * env
                                        activeWeight += env
                                    }
                                }
                                
                                // Accumulate Kick drum procedural Chladni pattern (deep low mode n=2, m=3, style=1 cosine sum)
                                if kickLevel > 0.01 {
                                    let kickVal = calculateChladni(u: wu, v: wv, n: 2.0, m: 3.0, style: 1, time: time)
                                    chladniVal += kickVal * kickLevel * 1.2
                                    activeWeight += kickLevel * 1.2
                                }
                                
                                // Accumulate Snare drum procedural Chladni pattern (medium-high mode n=5, m=6, style=2 sine diff)
                                if snareLevel > 0.01 {
                                    let snareVal = calculateChladni(u: wu, v: wv, n: 5.0, m: 6.0, style: 2, time: time)
                                    chladniVal += snareVal * snareLevel * 1.0
                                    activeWeight += snareLevel * 1.0
                                }
                                
                                if activeWeight > 0 {
                                    chladniVal = chladniVal / activeWeight
                                }
                                
                                // Nodal lines are where amplitude is near 0 (sand accumulates at plate nodes)
                                let chladniNodal = max(0.0, 1.0 - abs(chladniVal) * 3.8)
                                
                                // 3. Blend circular ripples and Chladni sand shapes based on active plate vibration
                                let baseIntensity = (1.0 - totalActivity) * circularRipple + totalActivity * chladniNodal
                                
                                // Add extra local drum flash/sparkle overlay for visual punch
                                // Kick hit effect: heavy center expansion dome
                                let kickPulse = kickLevel * max(0.0, 1.0 - progress * 1.6)
                                
                                // Snare hit effect: subtle vertical/horizontal cross lines on snare hits
                                let snareCross = max(0.0, 1.0 - min(abs(u), abs(v)) * 8.0) * snareLevel * 0.4
                                let finalIntensity = min(1.0, baseIntensity + snareCross)
                                
                                // Wave intensity scales with overall sound
                                let waveIntensity = finalIntensity * (0.15 + levelScale * 1.6)
                                
                                // Pixel scale: scales up on wave parts, boosted by Kick base punch
                                var scale = 0.5 + finalIntensity * 0.5 * (1.0 + levelScale * 0.4) + kickPulse * 0.35
                                
                                // Hi-hat hit effect: fast sparkling metallic grain dust
                                let hatSparkle = ((r * 31 + c * 17) % 7 == 0) ? hatLevel * 0.6 : 0.0
                                
                                // Opacity: background pixels are dim, wave is bright, boosted by Kick and Hat sparkles
                                var opacity = (0.04 + waveIntensity * 0.75 + kickPulse * 0.4 + hatSparkle) * edgeFade
                                
                                // 4. Border pixel visualizer: drum hits trigger pixels appearing at the popover border
                                let borderDist = min(x, size.width - x, y, size.height - y)
                                let borderRange: CGFloat = 28.0 // Width of the border zone in points
                                
                                if borderDist < borderRange {
                                    // Normalized distance from the absolute edge (0 = at edge, 1 = borderRange points inward)
                                    let edgeProgress = borderDist / borderRange
                                    
                                    // Smooth transition from edge to interior (brightest at the edge, fading as it goes in)
                                    let borderFade = 1.0 - edgeProgress
                                    
                                    // Perimeter coordinate: coordinate tracing around the square perimeter from 0...1
                                    var perimeterT: Double = 0.0
                                    if y <= borderRange { // Top edge
                                        perimeterT = x / size.width
                                    } else if x >= size.width - borderRange { // Right edge
                                        perimeterT = 1.0 + y / size.height
                                    } else if y >= size.height - borderRange { // Bottom edge
                                        perimeterT = 2.0 + (size.width - x) / size.width
                                    } else { // Left edge
                                        perimeterT = 3.0 + (size.height - y) / size.height
                                    }
                                    perimeterT /= 4.0 // Normalize to 0...1
                                    
                                    // Kick border wave: wide ripples propagating inward from the boundary
                                    let kickPhase = perimeterT * Double.pi * 4.0 + edgeProgress * Double.pi * 2.5 - time * 8.0
                                    let kickWave = sin(kickPhase) * 0.5 + 0.5
                                    let kickBorder = kickLevel * kickWave * borderFade * 0.95
                                    
                                    // Snare border wave: sharper, faster ripples propagating inward
                                    let snarePhase = perimeterT * Double.pi * 8.0 + edgeProgress * Double.pi * 4.0 - time * 14.0
                                    let snareWave = sin(snarePhase) * 0.5 + 0.5
                                    let snareBorder = snareLevel * snareWave * borderFade * 0.75
                                    
                                    // Hi-hat border wave: micro-sparkles shimmering and fading inward
                                    let hatNoise = sin(Double(r * 43 + c * 29) + time * 20.0) * 0.5 + 0.5
                                    let hatBorder = (hatNoise > 0.70) ? hatLevel * 0.8 * borderFade : 0.0
                                    
                                    let totalBorderIntensity = kickBorder + snareBorder + hatBorder
                                    
                                    if totalBorderIntensity > 0.01 {
                                        // Scale up border pixels on drum hits
                                        scale = max(scale, 0.4 + (1.0 + totalBorderIntensity * 0.5) * 0.6)
                                        // Make border pixels light up at the edge and fade inward, overriding edgeFade
                                        opacity = max(opacity, totalBorderIntensity)
                                    }
                                }
                                
                                let currentPixelSize = pixelSize * scale
                                
                                if opacity < 0.01 { continue }
                                
                                // Determine color (drums are a muted slate-grey, melody is white)
                                let drumActivity = kickLevel + snareLevel + hatLevel
                                let totalInput = melodyActivity + drumActivity
                                
                                var pixelColor = Color.white
                                if borderDist < borderRange {
                                    // Border pixels are purely drum-driven, draw them in muted slate-grey
                                    pixelColor = Color(red: 0.65, green: 0.68, blue: 0.72)
                                } else if totalInput > 0.01 {
                                    let drumColor = Color(red: 0.65, green: 0.68, blue: 0.72)
                                    let blend = min(1.0, drumActivity / totalInput)
                                    
                                    if blend > 0.9 {
                                        pixelColor = drumColor
                                    } else if blend > 0.1 {
                                        // Smoothly blend white and slate-grey
                                        let whiteAmt = 1.0 - blend
                                        pixelColor = Color(
                                            red: 1.0 * whiteAmt + 0.65 * blend,
                                            green: 1.0 * whiteAmt + 0.68 * blend,
                                            blue: 1.0 * whiteAmt + 0.72 * blend
                                        )
                                    }
                                }
                                
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
                                        with: .color(pixelColor.opacity(0.14 * waveIntensity * edgeFade))
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
                                    with: .color(pixelColor.opacity(opacity))
                                )
                            }
                        }
                    }
                }

                // Play / Stop button in the absolute geometric center (circle, no text)
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
                                    Circle()
                                        .fill(Color.white)
                                } else {
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: 1.5)
                                        .background(Circle().fill(Color.black)) // prevent showing pixel grid lines under transparent button
                                }
                            }
                        )
                }
                .buttonStyle(.plain)

                // Close/Quit button in the top right corner
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            if let window = hostingWindow {
                                NSAnimationContext.runAnimationGroup { ctx in
                                    ctx.duration = 0.22
                                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                                    window.animator().alphaValue = 0.0
                                } completionHandler: {
                                    Task { @MainActor in
                                        NSApp.terminate(nil)
                                    }
                                }
                            } else {
                                NSApp.terminate(nil)
                            }
                        }) {
                            Image(systemName: "power")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(isHoveringClose ? .white.opacity(0.8) : .white.opacity(0.35))
                                .animation(.easeInOut(duration: 0.15), value: isHoveringClose)
                                .padding(14)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isHoveringClose = hovering
                        }
                        .help("Quit AmbientGen")
                    }
                    Spacer()
                }
            }
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
            self.hostingWindow = window
            window.isOpaque = false
            window.backgroundColor = .clear
            window.styleMask = [.borderless]
            window.hasShadow = true
            window.invalidateShadow()
        })
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    /// Calculates the Chladni plate displacement at a given normalized coordinate.
    private func calculateChladni(u: Double, v: Double, n: Double, m: Double, style: Int, time: Double) -> Double {
        // Slow time-based LFO to drift the modes slightly (adds fluid organic morphing)
        let nMod = n + sin(time * 0.4) * 0.12
        let mMod = m + cos(time * 0.3) * 0.12
        
        switch style {
        case 0:
            return cos(nMod * Double.pi * u) * cos(mMod * Double.pi * v) -
                   cos(mMod * Double.pi * u) * cos(nMod * Double.pi * v)
        case 1:
            return cos(nMod * Double.pi * u) * cos(mMod * Double.pi * v) +
                   cos(mMod * Double.pi * u) * cos(nMod * Double.pi * v)
        case 2:
            return sin(nMod * Double.pi * u) * sin(mMod * Double.pi * v) -
                   sin(mMod * Double.pi * u) * sin(nMod * Double.pi * v)
        default:
            return cos(nMod * Double.pi * u) * sin(mMod * Double.pi * v) -
                   sin(mMod * Double.pi * u) * cos(nMod * Double.pi * v)
        }
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
                
                // Enable dynamic subclass to intercept orderOut and fade out smoothly
                makeWindowDynamicSubclass(window: window)
                
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

/// Dynamically subclasses the window at runtime to intercept `orderOut(_:)` and perform a smooth fade-out animation.
private func makeWindowDynamicSubclass(window: NSWindow) {
    let originalClass: AnyClass = object_getClass(window)!
    let cName = class_getName(originalClass)
    let className = String(cString: cName) + "_Animated"
    
    // Check if the class already exists
    var subclass: AnyClass? = objc_getClass(className) as? AnyClass
    if subclass == nil {
        subclass = objc_allocateClassPair(originalClass, className, 0)
        guard let subclass = subclass else { return }
        
        let orderOutSelector = #selector(NSWindow.orderOut(_:))
        guard let method = class_getInstanceMethod(originalClass, orderOutSelector) else { return }
        let typeEncoding = method_getTypeEncoding(method)
        
        let imp: @convention(block) (AnyObject, AnyObject?) -> Void = { selfObject, _ in
            guard let window = selfObject as? NSWindow else { return }
            
            MainActor.assumeIsolated {
                // If already transparent, hide immediately
                if window.alphaValue == 0.0 {
                    let originalImp = class_getMethodImplementation(originalClass, orderOutSelector)
                    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                    let fn = unsafeBitCast(originalImp, to: Fn.self)
                    fn(window, orderOutSelector, nil)
                    return
                }
                
                // Run fade out animation
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().alphaValue = 0.0
                } completionHandler: {
                    Task { @MainActor in
                        let originalImp = class_getMethodImplementation(originalClass, orderOutSelector)
                        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                        let fn = unsafeBitCast(originalImp, to: Fn.self)
                        fn(window, orderOutSelector, nil)
                        
                        // Reset alpha for next presentation
                        window.alphaValue = 1.0
                    }
                }
            }
        }
        
        let impAddress = imp_implementationWithBlock(imp)
        class_addMethod(subclass, orderOutSelector, impAddress, typeEncoding)
        objc_registerClassPair(subclass)
    }
    
    if let subclass = subclass {
        object_setClass(window, subclass)
    }
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
    ContentView()
}
