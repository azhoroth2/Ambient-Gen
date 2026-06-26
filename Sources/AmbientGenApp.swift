import SwiftUI

struct SVGRect: Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var rx: CGFloat
}

func parseSVG(url: URL) -> [SVGRect] {
    guard let content = try? String(contentsOf: url) else { return [] }
    var rects: [SVGRect] = []
    
    var searchRange = content.startIndex..<content.endIndex
    while let rectRange = content.range(of: "<rect", options: [], range: searchRange) {
        // Find the end of this rect tag
        let remainingRange = rectRange.upperBound..<content.endIndex
        guard let tagEndRange = content.range(of: "/>", options: [], range: remainingRange) else {
            break
        }
        
        let rectTag = String(content[rectRange.lowerBound...tagEndRange.upperBound])
        
        let width = extractDouble(from: rectTag, key: "width=\"") ?? 1.925
        let height = extractDouble(from: rectTag, key: "height=\"") ?? 1.925
        let rx = extractDouble(from: rectTag, key: "rx=\"") ?? 0.5
        
        var tx = extractDouble(from: rectTag, key: "x=\"") ?? 0.0
        var ty = extractDouble(from: rectTag, key: "y=\"") ?? 0.0
        
        if let matrixStart = rectTag.range(of: "matrix(1 0 0 -1 ") {
            let sub = rectTag[matrixStart.upperBound...]
            if let closeParen = sub.range(of: ")") {
                let matrixParams = sub[..<closeParen.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = matrixParams.components(separatedBy: " ")
                if parts.count >= 2,
                   let pX = Double(parts[0]),
                   let pY = Double(parts[1]) {
                    tx = pX
                    ty = pY
                }
            }
        }
        rects.append(SVGRect(x: CGFloat(tx), y: CGFloat(ty), width: CGFloat(width), height: CGFloat(height), rx: CGFloat(rx)))
        
        searchRange = tagEndRange.upperBound..<content.endIndex
    }
    
    return rects
}

private func extractDouble(from string: String, key: String) -> Double? {
    guard let range = string.range(of: key) else { return nil }
    let sub = string[range.upperBound...]
    guard let endQuote = sub.range(of: "\"") else { return nil }
    return Double(sub[..<endQuote.lowerBound])
}

struct MenuBarIconView: View {
    var audioEngine: AudioEngine
    let rects: [SVGRect]

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        if let url = Bundle.module.url(forResource: "Icon", withExtension: "svg") {
            self.rects = parseSVG(url: url)
        } else {
            self.rects = []
        }
    }

    private var activeRects: [SVGRect] {
        if !rects.isEmpty {
            return rects
        }
        // Fallback hardcoded values matching the original SVG
        let baseTranslateXs: [CGFloat] = [
            1.375, 3.29999, 5.22501, 7.14999, 9.07501,
            11.0, 12.925, 14.85, 16.775, 18.7
        ]
        let baseTranslateYs: [CGFloat] = [
            12.5249, 14.45, 16.3748, 14.45, 12.5249,
            10.5999, 8.6748, 6.74976, 8.6748, 10.5999
        ]
        return (0..<10).map { i in
            SVGRect(
                x: baseTranslateXs[i],
                y: baseTranslateYs[i],
                width: 1.925,
                height: 1.925,
                rx: 0.5
            )
        }
    }

    var body: some View {
        Group {
            if audioEngine.isPlaying {
                TimelineView(.periodic(from: Date(), by: 0.04)) { timelineContext in
                    let time = timelineContext.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        drawWave(context: context, size: size, time: time)
                    }
                }
            } else {
                Canvas { context, size in
                    drawWave(context: context, size: size, time: nil)
                }
            }
        }
        .frame(width: 22, height: 22)
    }

    private func drawWave(context: GraphicsContext, size: CGSize, time: Double?) {
        let rectsToDraw = activeRects
        for i in 0..<rectsToDraw.count {
            let r = rectsToDraw[i]
            
            let ty: CGFloat
            if let time = time {
                let bpm = audioEngine.bpm
                let speed = (bpm / 112.0) * 8.0
                
                // Animate Y coordinate as a sine wave
                let waveOffset = sin(time * speed - Double(i) * 0.7) * 3.5
                ty = r.y + CGFloat(waveOffset)
            } else {
                ty = r.y
            }
            
            let rect = CGRect(x: r.x, y: ty - r.height, width: r.width, height: r.height)
            let path = Path(roundedRect: rect, cornerRadius: r.rx)
            context.fill(path, with: .color(.primary))
        }
    }
}

@main
struct AmbientGenApp: App {
    @State private var audioEngine = AudioEngine()

    init() {
        // Run as an accessory app (menu bar utility, hides Dock icon)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(audioEngine: audioEngine)
        } label: {
            MenuBarIconView(audioEngine: audioEngine)
        }
        .menuBarExtraStyle(.window)
    }
}
