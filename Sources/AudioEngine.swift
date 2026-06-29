@preconcurrency import AVFoundation
import Observation
import MediaPlayer

/// Shared DSP state read by the real-time audio thread and written by the main thread.
///
/// Simple `Double` loads and stores on 64-bit Apple ARM hardware are
/// naturally atomic, so this is safe without locks for our use case
/// (single writer on main, single reader on audio thread).
final class DSPState: @unchecked Sendable {
    var leftFrequency: Double = 200.0
    var rightFrequency: Double = 208.0
    var targetAmplitude: Double = 0.12
    var currentAmplitude: Double = 0.0
    var phase: Double = 0.0

    // LFO state
    var lfoPhase: Double = 0.0
}

/// Shared state for the pink noise generator, kept separate from
/// oscillator DSP so each `AVAudioSourceNode` owns its own state.
final class PinkNoiseState: @unchecked Sendable {
    /// Voss-McCartney algorithm: 6 rows of random contributors
    var rows: [Double] = Array(repeating: 0.0, count: 6)
    var runningSum: Double = 0.0
    var index: Int = 0
    /// Simple xorshift64 PRNG state (non-zero seed)
    var rngState: UInt64 = 0xDEAD_BEEF_CAFE_1234

    // Vinyl crackle pop emulation state
    var popValue: Double = 0.0
}

/// Shared state for the generative melody voice.
final class MelodyState: @unchecked Sendable {
    struct Voice: Sendable {
        var frequency: Double = 0.0
        var phase: Double = 0.0
        var envelopeValue: Double = 0.0
        var stage: Int = 0 // 0=idle, 1=attack, 2=decay, 3=sustain, 4=release
        
        // Per-voice randomized parameters
        var amplitudeFactor: Double = 1.0
        var attackRate: Double = 0.0
        var decayRate: Double = 0.0
        var releaseTime: Double = 4.0
        var releaseRate: Double = 0.0
        var startReleaseLevel: Double = 0.8
        var triggerDelay: Int = 0
    }

    var voices: [Voice] = [Voice(), Voice(), Voice(), Voice(), Voice()]
    var activeVoiceIndex: Int = -1

    // Timer: samples remaining until next note trigger (aligned with drum start)
    var samplesUntilNext: Int = 88200

    // Chord progression state
    var currentChordIndex: Int = 0
    var lastNoteScaleIndex: Int = 3
    var beatsInCurrentChord: Int = 0

    // PRNG (separate seed from pink noise)
    var rngState: UInt64 = 0xCAFE_BABE_DEAD_BEEF

    // Wow & Flutter LFO phases
    var wowPhase: Double = 0.0
    var flutterPhase: Double = 0.0
    
    var bpm: Double = 112.0
    
    var patternIndex: Int = 0
    var activePatternIndex: Int = 0
}

/// Shared state for the generative procedural drums.
final class DrumState: @unchecked Sendable {
    var kickTime: Double = -1.0
    var kickPhase: Double = 0.0
    var kickEnvelope: Double = 0.0
    
    var snareTime: Double = -1.0
    var snarePhase: Double = 0.0
    var snareEnvelope: Double = 0.0
    
    var hatTime: Double = -1.0
    var hatLastNoise: Double = 0.0
    var hatVolume: Double = 0.0
    var hatEnvelope: Double = 0.0
    
    // Step sequencer: starts after a ~2s initial delay
    var samplesUntilNextStep: Int = 88200
    var currentStep: Int = 0
    
    // PRNG for snare and hat noise
    var rngState: UInt64 = 0x5678_ABCD_1234_EF01
    
    var bpm: Double = 112.0
    
    var pixelateCounter: Int = 0
    var pixelateHoldValue: Float = 0.0
    var patternIndex: Int = 0
    var activePatternIndex: Int = 0
    
    // Drum filters state
    var filterState: Float = 0.0
    var snareFilterLP: Double = 0.0
    var snareFilterHP: Double = 0.0
    var hatFilterLP: Double = 0.0
    var hatFilterHP: Double = 0.0
}

/// Shared state for the generative sub-bass voice.
final class BassState: @unchecked Sendable {
    var frequency: Double = 0.0
    var phase: Double = 0.0
    var envelopeValue: Double = 0.0
    var stage: Int = 0 // 0=idle, 1=attack, 2=decay, 3=sustain, 4=release
    
    var releaseRate: Double = 0.0
    var startReleaseLevel: Double = 0.7
    
    var pendingFrequency: Double = 0.0
    var triggerDelay: Int = 0
    
    var stepsRemaining: Int = 0
    
    var samplesUntilNextStep: Int = 88200
    var currentStep: Int = 0
    
    var rngState: UInt64 = 0x9876_FEDC_BA98_7654
    
    var bpm: Double = 112.0
    
    var patternIndex: Int = 0
    var activePatternIndex: Int = 0
}

/// Real-time binaural-beat audio engine with pink noise and LFO.
///
/// Signal chain:
/// ```
/// Oscillators (stereo, LFO-modulated) ──→ Mixer ←── Pink Noise (stereo)
///                                           │
///                                     AVAudioUnitReverb (largeChamber, 40% wet)
///                                           │
///                                        Output
/// ```
struct VisualVoiceInfo: Sendable {
    var frequency: Double
    var envelopeValue: Double
}

@Observable
final class AudioEngine: @unchecked Sendable {

    // MARK: - Public State

    /// Whether the engine is currently playing.
    private(set) var isPlaying: Bool = false

    /// Real-time audio amplitude level (0...1)
    private(set) var currentLevel: Double = 0.0

    /// Real-time melody voice states for visualization
    private(set) var activeVoices: [VisualVoiceInfo] = []

    /// Real-time drum envelopes for visual patterns
    private(set) var kickLevel: Double = 0.0
    private(set) var snareLevel: Double = 0.0
    private(set) var hatLevel: Double = 0.0

    /// Master volume scaling (0...1)
    var globalVolume: Double = 1.0 {
        didSet {
            if isPlaying {
                engine.mainMixerNode.outputVolume = Float(globalVolume)
            }
        }
    }

    /// Tempo (BPM) of the sequencers (50...200)
    var bpm: Double = 112.0 {
        didSet {
            melodyDsp.bpm = bpm
            drumDsp.bpm = bpm
            bassDsp.bpm = bpm
        }
    }

    /// Volumes for each sound source (0...1)
    var oscVolume: Double = 0.20 {
        didSet { oscNode?.volume = Float(oscVolume) }
    }
    var noiseVolume: Double = 0.14 {
        didSet { noiseNode?.volume = Float(noiseVolume) }
    }
    var melodyVolume: Double = 0.22 {
        didSet { melodyNode?.volume = Float(melodyVolume) }
    }
    var bassVolume: Double = 0.40 {
        didSet { bassNode?.volume = Float(bassVolume) }
    }
    var drumsVolume: Double = 0.86 {
        didSet { drumNode?.volume = Float(drumsVolume) }
    }

    // MARK: - Private Audio Graph

    private let engine = AVAudioEngine()
    private var oscNode: AVAudioSourceNode?
    private var noiseNode: AVAudioSourceNode?
    private var melodyNode: AVAudioSourceNode?
    private var bassNode: AVAudioSourceNode?
    private var drumNode: AVAudioSourceNode?
    private let reverb = AVAudioUnitReverb()

    // MARK: - DSP State (shared with render thread)

    private let dsp = DSPState()
    private let noiseDsp = PinkNoiseState()
    private let melodyDsp = MelodyState()
    private let drumDsp = DrumState()
    private let bassDsp = BassState()
    private var fadeTask: Task<Void, Never>?
    private var patternTimer: Timer?

    /// Amplitude ramp speed per sample. At 44100 Hz, ~20 ms ramp ≈ 882 samples.
    private static let rampStep: Double = 0.00113

    // LFO parameters (constants — no UI control yet)
    private static let lfoRate: Double = 0.1    // Hz — one breath cycle = 10 s
    private static let lfoDepth: Double = 0.15  // 0…1 modulation depth

    // Pink noise amplitude
    private static let noiseAmplitude: Float = 0.06

    // Melody parameters
    private static let melodyAmplitude: Double = 0.22
    private static let melodyAttackTime: Double = 1.5    // seconds
    private static let melodyDecayTime: Double = 0.5     // seconds
    private static let melodySustainLevel: Double = 0.8  // level
    private static let melodyReleaseTime: Double = 4.0   // seconds
    private static let melodySilenceChance: Double = 0.3 // 30% chance of rest
    private static let melodyDetune: Double = 1.5        // ±Hz random per note
    private static let baseScale: [Double] = [
        130.81, // C3 (0)
        146.83, // D3 (1)
        164.81, // E3 (2)
        174.61, // F3 (3)
        196.00, // G3 (4)
        220.00, // A3 (5)
        246.94, // B3 (6)
        261.63, // C4 (7)
        293.66, // D4 (8)
        329.63, // E4 (9)
        349.23, // F4 (10)
        392.00, // G4 (11)
        440.00, // A4 (12)
        493.88, // B4 (13)
        523.25  // C5 (14)
    ]

    // MARK: - Lifecycle

    init() {
        setupRemoteCommands()
    }

    // MARK: - Remote Controls

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.start()
            }
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.stop()
            }
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.toggle()
            }
            return .success
        }
        
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.stop()
            }
            return .success
        }
    }

    @MainActor
    private func updateNowPlaying() {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        nowPlayingInfoCenter.playbackState = isPlaying ? .playing : .stopped
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "Ambeat"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Ambient Generator"
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Public API

    @MainActor
    func start() {
        fadeTask?.cancel()
        patternTimer?.invalidate()
        setupIfNeeded()
        
        if !engine.isRunning {
            engine.mainMixerNode.outputVolume = 0.0
            do {
                try engine.start()
            } catch {
                print("AudioEngine: failed to start — \(error.localizedDescription)")
                return
            }
        }
        
        isPlaying = true
        updateNowPlaying()
        
        patternTimer = Timer.scheduledTimer(withTimeInterval: 180.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let nextPattern = (self.melodyDsp.patternIndex + 1) % 3
                self.melodyDsp.patternIndex = nextPattern
                self.drumDsp.patternIndex = nextPattern
                self.bassDsp.patternIndex = nextPattern
                print("AudioEngine: advanced pattern to \(nextPattern)")
            }
        }
        
        fadeTask = Task {
            let duration = 1.5 // seconds
            let steps = 50
            let interval = duration / Double(steps)
            let startVol = Double(engine.mainMixerNode.outputVolume)
            
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let vol = startVol + (self.globalVolume - startVol) * t
                engine.mainMixerNode.outputVolume = Float(vol)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            engine.mainMixerNode.outputVolume = Float(self.globalVolume)
        }
    }

    @MainActor
    func stop() {
        fadeTask?.cancel()
        patternTimer?.invalidate()
        patternTimer = nil
        
        guard isPlaying else { return }
        isPlaying = false
        updateNowPlaying()
        
        fadeTask = Task {
            let duration = 1.5 // seconds
            let steps = 50
            let interval = duration / Double(steps)
            let startVol = Double(engine.mainMixerNode.outputVolume)
            
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let vol = startVol * (1.0 - t)
                engine.mainMixerNode.outputVolume = Float(vol)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            
            engine.mainMixerNode.outputVolume = 0.0
            engine.stop()
            dsp.currentAmplitude = 0.0
            self.currentLevel = 0.0
            self.activeVoices = []
            self.kickLevel = 0.0
            self.snareLevel = 0.0
            self.hatLevel = 0.0
            
            self.melodyDsp.samplesUntilNext = 88200
            self.melodyDsp.activeVoiceIndex = -1
            for i in 0..<5 {
                self.melodyDsp.voices[i] = MelodyState.Voice()
            }
            self.melodyDsp.patternIndex = 0
            self.melodyDsp.activePatternIndex = 0
            self.melodyDsp.currentChordIndex = 0
            self.melodyDsp.beatsInCurrentChord = 0
            
            self.drumDsp.kickTime = -1.0
            self.drumDsp.snareTime = -1.0
            self.drumDsp.hatTime = -1.0
            self.drumDsp.kickEnvelope = 0.0
            self.drumDsp.snareEnvelope = 0.0
            self.drumDsp.hatEnvelope = 0.0
            self.drumDsp.currentStep = 0
            self.drumDsp.samplesUntilNextStep = 88200
            self.drumDsp.patternIndex = 0
            self.drumDsp.activePatternIndex = 0
            self.drumDsp.filterState = 0.0
            self.drumDsp.snareFilterLP = 0.0
            self.drumDsp.snareFilterHP = 0.0
            self.drumDsp.hatFilterLP = 0.0
            self.drumDsp.hatFilterHP = 0.0
            
            self.bassDsp.frequency = 0.0
            self.bassDsp.envelopeValue = 0.0
            self.bassDsp.stage = 0
            self.bassDsp.currentStep = 0
            self.bassDsp.samplesUntilNextStep = 88200
            self.bassDsp.stepsRemaining = 0
            self.bassDsp.triggerDelay = 0
            self.bassDsp.patternIndex = 0
            self.bassDsp.activePatternIndex = 0
        }
    }

    @MainActor
    func toggle() {
        if isPlaying { stop() } else { start() }
    }

    // MARK: - Engine Setup

    private func setupIfNeeded() {
        guard oscNode == nil else { return }

        let sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // ── 1. Oscillator node (stereo, LFO-modulated) ──────────────

        let dsp = self.dsp
        let rampStep = Self.rampStep
        let lfoRate = Self.lfoRate
        let lfoDepth = Self.lfoDepth

        let osc = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let leftFreq = dsp.leftFrequency
            let rightFreq = dsp.rightFrequency
            let target = dsp.targetAmplitude
            var amp = dsp.currentAmplitude
            var ph = dsp.phase
            var lfoPh = dsp.lfoPhase

            let twoPi = 2.0 * Double.pi
            let lfoInc = twoPi * lfoRate / sampleRate

            for frame in 0..<Int(frameCount) {
                // Ramp base amplitude toward target to avoid clicks
                if amp < target {
                    amp = min(amp + rampStep, target)
                } else if amp > target {
                    amp = max(amp - rampStep, target)
                }

                // LFO: sine wave 0.1 Hz, depth 0.3
                // Maps sin(-1…1) → modulation factor (1-depth)…1 = 0.7…1.0
                let lfo = 1.0 - lfoDepth * 0.5 * (1.0 - sin(lfoPh))
                let modulatedAmp = amp * lfo

                // Recover time in seconds from accumulated phase
                let t = ph / twoPi
                let lSample = Float(sin(twoPi * leftFreq * t) * modulatedAmp)
                let rSample = Float(sin(twoPi * rightFreq * t) * modulatedAmp)

                // Write to stereo buffers (non-interleaved standard format)
                if abl.count >= 2 {
                    let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self)
                    let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
                    leftPtr?[frame] = lSample
                    rightPtr?[frame] = rSample
                }

                ph += twoPi / sampleRate
                if ph >= twoPi * 10.0 {
                    ph -= twoPi * 10.0
                }

                lfoPh += lfoInc
                if lfoPh >= twoPi {
                    lfoPh -= twoPi
                }
            }

            dsp.currentAmplitude = amp
            dsp.phase = ph
            dsp.lfoPhase = lfoPh
            return noErr
        }

        // ── 2. Pink noise node (stereo + vinyl crackle) ─────────────

        let noiseDsp = self.noiseDsp
        let noiseAmp = Self.noiseAmplitude

        let noise = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                var sample = Self.nextPinkSample(noiseDsp) * noiseAmp

                // Vinyl crackle emulator: random warm pops with fast decay
                let crackleChance = Self.nextRandomUnit(&noiseDsp.rngState)
                if crackleChance < 0.00004 { // average ~1.8 pops per second
                    // Trigger a pop: positive or negative impulse with random height
                    let direction = Self.nextRandom(&noiseDsp.rngState) > 0.0 ? 1.0 : -1.0
                    let popHeight = 0.04 + Self.nextRandomUnit(&noiseDsp.rngState) * 0.14
                    noiseDsp.popValue = direction * popHeight
                }
                
                // Add pop value to the noise sample
                sample += Float(noiseDsp.popValue)
                
                // Exponential decay of the pop: 94% per sample (decays to ~0 in 1-2 ms)
                noiseDsp.popValue *= 0.94

                // Write same sample to both channels
                if abl.count >= 2 {
                    let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self)
                    let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
                    leftPtr?[frame] = sample
                    rightPtr?[frame] = sample
                }
            }
            return noErr
        }

        // ── 3. Melody node (stereo, generative) ─────────────────────

        let melDsp = self.melodyDsp
        let melAmp = Self.melodyAmplitude

        let melody = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)

            let twoPi = 2.0 * Double.pi

            for frame in 0..<Int(frameCount) {
                // ── Note scheduling ──
                melDsp.samplesUntilNext -= 1
                if melDsp.samplesUntilNext <= 0 {
                    // Transition all currently active voices that are NOT already releasing to release
                    for i in 0..<5 {
                        if melDsp.voices[i].stage != 0 && melDsp.voices[i].stage != 4 {
                            melDsp.voices[i].stage = 4 // Release
                            melDsp.voices[i].startReleaseLevel = melDsp.voices[i].envelopeValue
                            let rTime = melDsp.voices[i].releaseTime
                            melDsp.voices[i].releaseRate = melDsp.voices[i].envelopeValue / (rTime * sampleRate)
                        }
                    }
                    melDsp.activeVoiceIndex = -1

                    // Chord progression subsets of indices in `baseScale`
                    // baseScale: C3, D3, E3, F3, G3, A3, B3, C4, D4, E4, F4, G4, A4, B4, C5
                    let chords: [[Int]]
                    switch melDsp.activePatternIndex {
                    case 1:
                        // Pattern 1: Warm Jazz Turnaround (Dm7 -> G7 -> Cmaj7 -> A7)
                        chords = [
                            [1, 3, 5, 7, 9, 11],    // Dm7
                            [4, 6, 8, 10, 12],      // G7
                            [0, 2, 4, 6, 7, 9, 11],  // Cmaj7
                            [5, 7, 9, 11, 13]       // A7
                        ]
                    case 2:
                        // Pattern 2: Modal Lydian (Fmaj7#11 -> G/F -> Em7 -> Am9)
                        chords = [
                            [3, 5, 7, 9, 11, 13],  // Fmaj7#11
                            [4, 6, 8, 10, 11],     // G/F
                            [2, 4, 6, 8, 11, 13],  // Em7
                            [5, 7, 9, 11, 13, 14]  // Am9
                        ]
                    default:
                        // Pattern 0: Classic Pentatonic / Diatonic (Am7 -> Fmaj7 -> Cmaj7 -> G6)
                        chords = [
                            [5, 7, 9, 11, 12, 14],          // Am7
                            [3, 5, 7, 9, 10, 12, 14],       // Fmaj7
                            [0, 2, 4, 6, 7, 9, 11, 13, 14],  // Cmaj7
                            [1, 2, 4, 6, 8, 9, 11, 13]       // G6
                        ]
                    }
                    
                    let currentChord = chords[melDsp.currentChordIndex]
                    
                    // Decide duration of the note in beats (calculated dynamically from bpm)
                    let beatLengthSamples = Int((60.0 / melDsp.bpm) * sampleRate)
                    
                    // Choose duration (1, 2, 3, 4, 6, or 8 beats)
                    let durRoll = Self.nextRandomUnit(&melDsp.rngState)
                    let durationBeats: Int
                    if durRoll < 0.15 {
                        durationBeats = 1 // Quarter note
                    } else if durRoll < 0.40 {
                        durationBeats = 2 // Half note
                    } else if durRoll < 0.60 {
                        durationBeats = 3 // Dotted half note
                    } else if durRoll < 0.85 {
                        durationBeats = 4 // Whole note
                    } else if durRoll < 0.95 {
                        durationBeats = 6 // Dotted whole note
                    } else {
                        durationBeats = 8 // Long pad
                    }
                    
                    // Update chord progression
                    melDsp.beatsInCurrentChord += durationBeats
                    if melDsp.beatsInCurrentChord >= 16 {
                        melDsp.beatsInCurrentChord = 0
                        melDsp.currentChordIndex = (melDsp.currentChordIndex + 1) % 4
                    }
                    
                    if melDsp.beatsInCurrentChord == 0 {
                        melDsp.activePatternIndex = melDsp.patternIndex
                    }
                    
                    // Closure to trigger a voice
                    let triggerVoice = { (freq: Double, amp: Double, attRate: Double, decRate: Double, relTime: Double, delay: Int) in
                        var selectedVoiceIndex = -1
                        for i in 0..<5 {
                            if melDsp.voices[i].stage == 0 {
                                selectedVoiceIndex = i
                                break
                            }
                        }
                        if selectedVoiceIndex == -1 {
                            var minVal = Double.greatestFiniteMagnitude
                            for i in 0..<5 {
                                if melDsp.voices[i].envelopeValue < minVal {
                                    minVal = melDsp.voices[i].envelopeValue
                                    selectedVoiceIndex = i
                                }
                            }
                        }
                        if selectedVoiceIndex >= 0 {
                            melDsp.voices[selectedVoiceIndex].frequency = freq
                            melDsp.voices[selectedVoiceIndex].phase = 0.0
                            melDsp.voices[selectedVoiceIndex].envelopeValue = 0.0
                            melDsp.voices[selectedVoiceIndex].stage = 1 // Attack
                            melDsp.voices[selectedVoiceIndex].amplitudeFactor = amp
                            melDsp.voices[selectedVoiceIndex].attackRate = attRate
                            melDsp.voices[selectedVoiceIndex].decayRate = decRate
                            melDsp.voices[selectedVoiceIndex].releaseTime = relTime
                            melDsp.voices[selectedVoiceIndex].releaseRate = 0.0
                            melDsp.voices[selectedVoiceIndex].startReleaseLevel = 0.8
                            melDsp.voices[selectedVoiceIndex].triggerDelay = delay
                            melDsp.activeVoiceIndex = selectedVoiceIndex
                        }
                    }
                    
                    // 15% chance of playing silence (rests/pause in the pad melody)
                    let playChance = Self.nextRandomUnit(&melDsp.rngState)
                    if playChance > 0.15 {
                        // Perform random walk or random pick on the chord scale index
                        let walkRoll = Self.nextRandomUnit(&melDsp.rngState)
                        var nextIndex = melDsp.lastNoteScaleIndex
                        
                        if walkRoll < 0.30 {
                            nextIndex = Int(Self.nextRandomUnit(&melDsp.rngState) * Double(currentChord.count))
                        } else {
                            let moveRoll = Self.nextRandomUnit(&melDsp.rngState)
                            if moveRoll < 0.20 {
                                nextIndex += 1
                            } else if moveRoll < 0.40 {
                                nextIndex -= 1
                            } else if moveRoll < 0.55 {
                                nextIndex += 2
                            } else if moveRoll < 0.70 {
                                nextIndex -= 2
                            } else if moveRoll < 0.80 {
                                nextIndex += 3
                            } else if moveRoll < 0.90 {
                                nextIndex -= 3
                            }
                        }
                        
                        // Clamp index to the chord scale size
                        if nextIndex < 0 {
                            nextIndex = 0
                        } else if nextIndex >= currentChord.count {
                            nextIndex = currentChord.count - 1
                        }
                        
                        melDsp.lastNoteScaleIndex = nextIndex
                        
                        // Decide chord density: 20% Triad, 40% Dyad, 40% Solo
                        let densityRoll = Self.nextRandomUnit(&melDsp.rngState)
                        let offsets: [Int]
                        if densityRoll < 0.20 {
                            offsets = [0, 2, 4]
                        } else if densityRoll < 0.60 {
                            offsets = [0, 2]
                        } else {
                            offsets = [0]
                        }
                        
                        // Apply octave shifting (adds variety in high/low registers)
                        var octaveShift = 1.0
                        let octaveRoll = Self.nextRandomUnit(&melDsp.rngState)
                        if octaveRoll < 0.12 {
                            octaveShift = 2.0
                        } else if octaveRoll < 0.20 {
                            octaveShift = 0.5
                        }
                        
                        // Scale envelope times based on duration to prevent cut-offs for faster notes
                        let durationSecs = Double(durationBeats) * (Double(beatLengthSamples) / sampleRate)
                        
                        let maxAttack = min(2.2, durationSecs * 0.4)
                        let minAttack = min(1.2, durationSecs * 0.2)
                        let randomizedAttackTime = minAttack + Self.nextRandomUnit(&melDsp.rngState) * (maxAttack - minAttack)
                        let attackRate = 1.0 / (randomizedAttackTime * sampleRate)
                        
                        let maxDecay = min(0.6, durationSecs * 0.2)
                        let minDecay = min(0.4, durationSecs * 0.1)
                        let randomizedDecayTime = minDecay + Self.nextRandomUnit(&melDsp.rngState) * (maxDecay - minDecay)
                        let decayRate = 0.2 / (randomizedDecayTime * sampleRate)
                        
                        let randomizedReleaseTime = (2.0 + Self.nextRandomUnit(&melDsp.rngState) * 2.0) * min(2.0, Double(durationBeats) * 0.5)
                        
                        for offset in offsets {
                            let offsetIdx = nextIndex + offset
                            let scaleIdx: Int
                            let octaveMul: Double
                            if offsetIdx < currentChord.count {
                                scaleIdx = currentChord[offsetIdx]
                                octaveMul = 1.0
                            } else {
                                scaleIdx = currentChord[offsetIdx % currentChord.count]
                                octaveMul = 2.0
                            }
                            
                            let baseFreq = Self.baseScale[scaleIdx]
                            let detune = (Self.nextRandomUnit(&melDsp.rngState) * 2.0 - 1.0) * 1.2
                            let frequency = (baseFreq + detune) * octaveShift * octaveMul
                            let ampFactor = (0.7 + Self.nextRandomUnit(&melDsp.rngState) * 0.3) / Double(offsets.count)
                            
                            let baseDelay: Int
                            if offset == 0 {
                                baseDelay = Int(Self.nextRandomUnit(&melDsp.rngState) * 400.0)
                            } else if offset == 2 {
                                baseDelay = 800 + Int(Self.nextRandomUnit(&melDsp.rngState) * 600.0)
                            } else {
                                baseDelay = 1600 + Int(Self.nextRandomUnit(&melDsp.rngState) * 800.0)
                            }
                            
                            triggerVoice(frequency, ampFactor, attackRate, decayRate, randomizedReleaseTime, baseDelay)
                        }
                    }
                    
                    melDsp.samplesUntilNext = durationBeats * beatLengthSamples
                }

                // ── Synthesis & Envelope ──
                var sample: Float = 0.0
                
                // Calculate wow & flutter pitch warp factors
                melDsp.wowPhase += twoPi * 0.38 / sampleRate
                if melDsp.wowPhase >= twoPi { melDsp.wowPhase -= twoPi }
                
                melDsp.flutterPhase += twoPi * 11.5 / sampleRate
                if melDsp.flutterPhase >= twoPi { melDsp.flutterPhase -= twoPi }
                
                let wow = sin(melDsp.wowPhase) * 0.0038
                let flutter = sin(melDsp.flutterPhase) * 0.0018
                let pitchWarp = 1.0 + wow + flutter
                
                for i in 0..<5 {
                    var voice = melDsp.voices[i]
                    if voice.stage == 0 { continue }

                    if voice.triggerDelay > 0 {
                        voice.triggerDelay -= 1
                        melDsp.voices[i] = voice
                        continue
                    }

                    // Process envelope
                    switch voice.stage {
                    case 1: // Attack
                        voice.envelopeValue += voice.attackRate
                        if voice.envelopeValue >= 1.0 {
                            voice.envelopeValue = 1.0
                            voice.stage = 2 // Decay
                        }
                    case 2: // Decay
                        voice.envelopeValue -= voice.decayRate
                        if voice.envelopeValue <= 0.8 {
                            voice.envelopeValue = 0.8
                            voice.stage = 3 // Sustain
                        }
                    case 3: // Sustain
                        break
                    case 4: // Release
                        voice.envelopeValue -= voice.releaseRate
                        if voice.envelopeValue <= 0.0 {
                            voice.envelopeValue = 0.0
                            voice.stage = 0 // Idle
                        }
                    default:
                        break
                    }

                    if voice.stage != 0 {
                        // Apply smooth Hermite interpolation for cross-fades
                        let gain: Double
                        switch voice.stage {
                        case 1: // Attack: 0.0 to 1.0
                            gain = Self.smoothStep(voice.envelopeValue)
                        case 2: // Decay: 1.0 to 0.8
                            let t = (voice.envelopeValue - 0.8) / 0.2
                            gain = 0.8 + 0.2 * Self.smoothStep(t)
                        case 3: // Sustain: constant 0.8
                            gain = 0.8
                        case 4: // Release
                            let startLevel = voice.startReleaseLevel
                            if startLevel > 0.0 {
                                let t = voice.envelopeValue / startLevel
                                gain = startLevel * Self.smoothStep(t)
                            } else {
                                gain = 0.0
                            }
                        default:
                            gain = 0.0
                        }

                        let ph = voice.phase
                        // Harmonics synthesis: fundamental (1.0), 2nd (0.3), 3rd (0.15)
                        let signal = sin(ph) * 1.0 + sin(ph * 2.0) * 0.3 + sin(ph * 3.0) * 0.15
                        
                        // Warm tape saturation: rational approximation of tanh (soft clipping)
                        let saturated = signal / (1.0 + abs(signal) * 0.25)
                        sample += Float(saturated * gain * voice.amplitudeFactor * melAmp)

                        voice.phase += twoPi * (voice.frequency * pitchWarp) / sampleRate
                        if voice.phase >= twoPi {
                            voice.phase -= twoPi
                        }
                    }

                    melDsp.voices[i] = voice
                }

                // Write same sample to both channels (centered melody)
                if abl.count >= 2 {
                    let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self)
                    let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
                    leftPtr?[frame] = sample
                    rightPtr?[frame] = sample
                }
            }
            return noErr
        }

        // ── 4. Drum node (stereo, procedural lo-fi beats) ───────────

        let drumDsp = self.drumDsp

        let drums = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                // 1. Sequencer step timing
                drumDsp.samplesUntilNextStep -= 1
                if drumDsp.samplesUntilNextStep <= 0 {
                    let beatLengthSamples = (60.0 / drumDsp.bpm) * sampleRate
                    drumDsp.samplesUntilNextStep = Int(beatLengthSamples / 4.0)
                    
                    let step = drumDsp.currentStep
                    
                    // Sync patternIndex on step 0
                    if step == 0 {
                        drumDsp.activePatternIndex = drumDsp.patternIndex
                    }
                    
                    let pattern = drumDsp.activePatternIndex
                    var triggerKick = false
                    var triggerSnare = false
                    var triggerHat = false
                    var accent = false
                    
                    switch pattern {
                    case 1:
                        // Pattern 1: Shaker style
                        triggerHat = true
                        accent = (step % 4 == 0)
                        
                        if step == 0 {
                            triggerKick = true
                        } else if step == 8 {
                            triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.90
                        } else if step == 11 {
                            triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.80
                        }
                        
                        if step == 4 || step == 12 {
                            triggerSnare = true
                        }
                        
                    case 2:
                        // Pattern 2: Halftime Ambient
                        if step % 2 == 1 {
                            triggerHat = Self.nextRandomUnit(&drumDsp.rngState) < 0.80
                            accent = (step % 4 == 1)
                        }
                        
                        if step == 0 {
                            triggerKick = true
                        } else if step == 10 {
                            triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.80
                        }
                        
                        if step == 8 {
                            triggerSnare = true
                        }
                        
                    default:
                        // Pattern 0: Classic Boom-Bap
                        if step == 0 {
                            triggerKick = true
                        } else if step == 8 {
                            triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.90
                        } else if step == 10 {
                            triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.70
                        } else if step == 6 || step == 14 {
                            triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.15
                        }
                        
                        if step == 4 || step == 12 {
                            triggerSnare = true
                        } else if step == 15 {
                            triggerSnare = Self.nextRandomUnit(&drumDsp.rngState) < 0.20
                        }
                        
                        if step % 2 == 0 {
                            triggerHat = Self.nextRandomUnit(&drumDsp.rngState) < 0.95
                            accent = (step % 4 == 0)
                        } else {
                            triggerHat = Self.nextRandomUnit(&drumDsp.rngState) < 0.18
                        }
                    }
                    
                    if triggerKick {
                        drumDsp.kickTime = 0.0
                        drumDsp.kickPhase = 0.0
                    }
                    if triggerSnare {
                        drumDsp.snareTime = 0.0
                        drumDsp.snarePhase = 0.0
                    }
                    if triggerHat {
                        drumDsp.hatTime = 0.0
                        let baseVol = accent ? 0.06 : 0.03
                        drumDsp.hatVolume = baseVol + Self.nextRandomUnit(&drumDsp.rngState) * 0.015
                    }
                    
                    drumDsp.currentStep = (step + 1) % 16
                }
                
                // 2. Synthesize instruments
                var sample: Float = 0.0
                
                // Kick drum synthesis
                if drumDsp.kickTime >= 0.0 {
                    // Stage 1 fast sweep for transient click + Stage 2 body sweep
                    let sweep1 = 150.0 * exp(-drumDsp.kickTime * 140.0)
                    let sweep2 = 46.0 + 84.0 * exp(-drumDsp.kickTime * 28.0)
                    let freq = sweep1 + sweep2
                    drumDsp.kickPhase += 2.0 * Double.pi * freq / sampleRate
                    let kickVal = sin(drumDsp.kickPhase)
                    // Soft saturation for warm tape distortion
                    let saturatedKick = kickVal / (1.0 + abs(kickVal) * 0.15)
                    let kickEnv = exp(-drumDsp.kickTime * 16.0)
                    sample += Float(saturatedKick * kickEnv * 0.24)
                    
                    drumDsp.kickEnvelope = kickEnv
                    drumDsp.kickTime += 1.0 / sampleRate
                    if drumDsp.kickTime > 0.22 {
                        drumDsp.kickTime = -1.0
                        drumDsp.kickEnvelope = 0.0
                    }
                } else {
                    drumDsp.kickEnvelope = 0.0
                }
                
                // Snare drum synthesis
                if drumDsp.snareTime >= 0.0 {
                    // Low tone body (180 Hz)
                    drumDsp.snarePhase += 2.0 * Double.pi * 180.0 / sampleRate
                    let snareVal = sin(drumDsp.snarePhase)
                    let bodyEnv = exp(-drumDsp.snareTime * 36.0)
                    
                    // Snare band-passed white noise rattle
                    let noiseVal = Self.nextRandom(&drumDsp.rngState)
                    // 1-pole HP filter at ~600Hz
                    drumDsp.snareFilterHP = noiseVal * 0.82 + drumDsp.snareFilterHP * 0.18
                    let hpNoise = noiseVal - drumDsp.snareFilterHP
                    // 1-pole LP filter at ~4000Hz
                    drumDsp.snareFilterLP = hpNoise * 0.40 + drumDsp.snareFilterLP * 0.60
                    let bpNoise = drumDsp.snareFilterLP
                    
                    let noiseEnv = exp(-drumDsp.snareTime * 14.0)
                    
                    // Mix body and noise
                    let snareMix = snareVal * bodyEnv * 0.38 + bpNoise * noiseEnv * 0.62
                    let saturatedSnare = snareMix / (1.0 + abs(snareMix) * 0.15)
                    sample += Float(saturatedSnare * 0.14)
                    
                    drumDsp.snareEnvelope = bodyEnv * 0.38 + noiseEnv * 0.62
                    drumDsp.snareTime += 1.0 / sampleRate
                    if drumDsp.snareTime > 0.25 {
                        drumDsp.snareTime = -1.0
                        drumDsp.snareEnvelope = 0.0
                    }
                } else {
                    drumDsp.snareEnvelope = 0.0
                }
                
                // Hi-Hat synthesis
                if drumDsp.hatTime >= 0.0 {
                    let noiseVal = Self.nextRandom(&drumDsp.rngState)
                    // Bandpass filter the noise centered around 10kHz
                    // 1-pole HP at ~7kHz
                    drumDsp.hatFilterHP = noiseVal * 0.45 + drumDsp.hatFilterHP * 0.55
                    let hpHat = noiseVal - drumDsp.hatFilterHP
                    // 1-pole LP at ~13kHz
                    drumDsp.hatFilterLP = hpHat * 0.65 + drumDsp.hatFilterLP * 0.35
                    let bpHat = drumDsp.hatFilterLP
                    
                    let hatEnv = exp(-drumDsp.hatTime * 85.0)
                    sample += Float(bpHat * hatEnv * drumDsp.hatVolume * 1.2) // slightly boost for clarity
                    
                    drumDsp.hatEnvelope = hatEnv
                    drumDsp.hatTime += 1.0 / sampleRate
                    if drumDsp.hatTime > 0.05 {
                        drumDsp.hatTime = -1.0
                        drumDsp.hatEnvelope = 0.0
                    }
                } else {
                    drumDsp.hatEnvelope = 0.0
                }
                
                // 3. Apply Bitcrusher (4x downsampling, 8-bit amplitude quantization)
                drumDsp.pixelateCounter += 1
                if drumDsp.pixelateCounter >= 4 {
                    drumDsp.pixelateCounter = 0
                    let clamped = max(-1.0, min(1.0, sample))
                    drumDsp.pixelateHoldValue = Float(round(Double(clamped) * 256.0) / 256.0)
                }
                let crushedSample = drumDsp.pixelateHoldValue
                
                // 4. Analog Reconstruction Filter (Roll off harsh aliasing high frequency hiss at ~4.5 kHz)
                let filterAlpha: Float = 0.28
                drumDsp.filterState = crushedSample * filterAlpha + drumDsp.filterState * (1.0 - filterAlpha)
                let filteredSample = drumDsp.filterState
                
                // Write mono sample to stereo output buffers
                if abl.count >= 2 {
                    let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self)
                    let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
                    leftPtr?[frame] = filteredSample
                    rightPtr?[frame] = filteredSample
                }
            }
            return noErr
        }

        // ── 5. Bass node (stereo, generative sub-bass) ──────────────

        let bassDsp = self.bassDsp
        let melodyDsp = self.melodyDsp
        let bass = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                // 1. Sequencer step timing
                bassDsp.samplesUntilNextStep -= 1
                if bassDsp.samplesUntilNextStep <= 0 {
                    let beatLengthSamples = (60.0 / bassDsp.bpm) * sampleRate
                    bassDsp.samplesUntilNextStep = Int(beatLengthSamples / 4.0)
                    
                    let step = bassDsp.currentStep
                    
                    // Sync patternIndex on step 0
                    if step == 0 {
                        bassDsp.activePatternIndex = bassDsp.patternIndex
                    }
                    
                    let pattern = bassDsp.activePatternIndex
                    var playNote = false
                    var noteSteps = 2
                    var frequencyMultiplier = 1.0
                    
                    switch pattern {
                    case 1:
                        // Pattern 1: Jazz walking (0, 4, 8, 12)
                        if step == 0 {
                            playNote = true
                            noteSteps = 3
                            frequencyMultiplier = 1.0
                        } else if step == 4 {
                            playNote = true
                            noteSteps = 3
                            frequencyMultiplier = 1.2
                        } else if step == 8 {
                            playNote = true
                            noteSteps = 3
                            frequencyMultiplier = 1.5
                        } else if step == 12 {
                            playNote = true
                            noteSteps = 3
                            frequencyMultiplier = 2.0
                        }
                    case 2:
                        // Pattern 2: Halftime sub (0, 10)
                        if step == 0 {
                            playNote = true
                            noteSteps = 8
                            frequencyMultiplier = 1.0
                        } else if step == 10 {
                            playNote = true
                            noteSteps = 4
                            frequencyMultiplier = 1.0
                        }
                    default:
                        // Pattern 0: Classic Boom-Bap syncopated (0, 6, 8, 10)
                        if step == 0 {
                            playNote = true
                            noteSteps = 3
                            frequencyMultiplier = 1.0
                        } else if step == 6 {
                            playNote = true
                            noteSteps = 2
                            frequencyMultiplier = (Self.nextRandomUnit(&bassDsp.rngState) < 0.5) ? 1.5 : 1.0
                        } else if step == 8 {
                            playNote = true
                            noteSteps = 3
                            frequencyMultiplier = 1.0
                        } else if step == 10 {
                            playNote = true
                            noteSteps = 2
                            frequencyMultiplier = 1.0
                        }
                    }
                    
                    // Release sub-bass after the steps have elapsed
                    if bassDsp.stepsRemaining > 0 {
                        bassDsp.stepsRemaining -= 1
                        if bassDsp.stepsRemaining == 0 {
                            if bassDsp.stage != 0 && bassDsp.stage != 4 {
                                bassDsp.stage = 4
                                bassDsp.startReleaseLevel = bassDsp.envelopeValue
                                bassDsp.releaseRate = bassDsp.envelopeValue / (0.35 * sampleRate) // 350ms release
                            }
                        }
                    }
                    
                    if playNote {
                        let targetFreq = Self.getBassFrequency(pattern: pattern, chordIndex: melodyDsp.currentChordIndex)
                        let finalFreq = targetFreq * frequencyMultiplier
                        
                        bassDsp.stepsRemaining = noteSteps
                        
                        if bassDsp.stage != 0 {
                            bassDsp.stage = 4
                            bassDsp.startReleaseLevel = bassDsp.envelopeValue
                            bassDsp.releaseRate = bassDsp.envelopeValue / (0.04 * sampleRate) // 40ms release
                            bassDsp.triggerDelay = Int(0.04 * sampleRate)
                            bassDsp.pendingFrequency = finalFreq
                        } else {
                            bassDsp.frequency = finalFreq
                            bassDsp.phase = 0.0
                            bassDsp.envelopeValue = 0.0
                            bassDsp.stage = 1 // Attack
                            bassDsp.triggerDelay = 0
                        }
                    }
                    
                    bassDsp.currentStep = (step + 1) % 16
                }
                
                // 2. Synthesize Bass sample
                var sample: Float = 0.0
                
                if bassDsp.triggerDelay > 0 {
                    bassDsp.triggerDelay -= 1
                    if bassDsp.triggerDelay == 0 {
                        bassDsp.frequency = bassDsp.pendingFrequency
                        bassDsp.phase = 0.0
                        bassDsp.envelopeValue = 0.0
                        bassDsp.stage = 1 // Attack
                    }
                }
                
                // Process envelope
                switch bassDsp.stage {
                case 1: // Attack
                    bassDsp.envelopeValue += 1.0 / (0.08 * sampleRate)
                    if bassDsp.envelopeValue >= 1.0 {
                        bassDsp.envelopeValue = 1.0
                        bassDsp.stage = 2 // Decay
                    }
                case 2: // Decay
                    bassDsp.envelopeValue -= (1.0 - 0.7) / (0.15 * sampleRate)
                    if bassDsp.envelopeValue <= 0.7 {
                        bassDsp.envelopeValue = 0.7
                        bassDsp.stage = 3 // Sustain
                    }
                case 3: // Sustain
                    break
                case 4: // Release
                    bassDsp.envelopeValue -= bassDsp.releaseRate
                    if bassDsp.envelopeValue <= 0.0 {
                        bassDsp.envelopeValue = 0.0
                        bassDsp.stage = 0 // Idle
                    }
                default:
                    break
                }
                
                if bassDsp.stage != 0 {
                    let gain = Self.smoothStep(bassDsp.envelopeValue)
                    let ph = bassDsp.phase
                    let signal = sin(ph) * 1.0 + sin(ph * 2.0) * 0.15
                    let saturated = signal / (1.0 + abs(signal) * 0.20)
                    
                    sample = Float(saturated * gain * 0.35)
                    
                    bassDsp.phase += 2.0 * Double.pi * bassDsp.frequency / sampleRate
                    if bassDsp.phase >= 2.0 * Double.pi {
                        bassDsp.phase -= 2.0 * Double.pi
                    }
                }
                
                // Write mono sample to stereo output buffers
                if abl.count >= 2 {
                    let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self)
                    let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self)
                    leftPtr?[frame] = sample
                    rightPtr?[frame] = sample
                }
            }
            return noErr
        }

        // ── 6. Reverb ───────────────────────────────────────────────

        reverb.loadFactoryPreset(.largeChamber)
        reverb.wetDryMix = 55

        // ── 7. Wire the graph ───────────────────────────────────────
        
        let mixer = engine.mainMixerNode

        engine.attach(osc)
        engine.attach(noise)
        engine.attach(melody)
        engine.attach(drums)
        engine.attach(bass)
        engine.attach(reverb)

        engine.connect(osc, to: mixer, format: stereoFormat)
        engine.connect(noise, to: mixer, format: stereoFormat)
        engine.connect(melody, to: mixer, format: stereoFormat)
        engine.connect(drums, to: mixer, format: stereoFormat)
        engine.connect(bass, to: mixer, format: stereoFormat)

        // Set initial node volumes from public properties
        osc.volume = Float(oscVolume)
        noise.volume = Float(noiseVolume)
        melody.volume = Float(melodyVolume)
        drums.volume = Float(drumsVolume)
        bass.volume = Float(bassVolume)

        // Disconnect default mixer→output, insert reverb in between
        engine.disconnectNodeOutput(mixer)
        engine.connect(mixer, to: reverb, format: stereoFormat)
        engine.connect(reverb, to: engine.outputNode, format: stereoFormat)

        oscNode = osc
        noiseNode = noise
        melodyNode = melody
        drumNode = drums
        bassNode = bass

        // Install tap to measure real-time amplitude of the final output (post-reverb)
        reverb.installTap(onBus: 0, bufferSize: 1024, format: stereoFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            
            var sum: Float = 0.0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            
            // Extract current melody voice states safely (read-only for visualization)
            let voices = melDsp.voices.map { voice in
                VisualVoiceInfo(frequency: voice.frequency, envelopeValue: voice.envelopeValue)
            }
            
            // Extract current drum envelopes safely
            let kickLvl = drumDsp.kickEnvelope
            let snareLvl = drumDsp.snareEnvelope
            let hatLvl = drumDsp.hatEnvelope
            
            // Update level on Main Actor (smoothed envelope)
            Task { @MainActor in
                let target = Double(rms)
                self.currentLevel = self.currentLevel * 0.85 + target * 0.15
                self.activeVoices = voices
                self.kickLevel = kickLvl
                self.snareLevel = snareLvl
                self.hatLevel = hatLvl
            }
        }
    }

    // MARK: - Pink Noise (Voss-McCartney algorithm)

    /// Generates one pink noise sample in the range roughly -1…1.
    ///
    /// Uses a simplified Voss-McCartney algorithm with 6 octave rows.
    /// Each row updates at half the rate of the previous one, producing
    /// the characteristic -3 dB/octave spectral slope of pink noise.
    private static func nextPinkSample(_ state: PinkNoiseState) -> Float {
        let numRows = state.rows.count  // 6

        // Determine which rows to update based on trailing zeros of index
        let idx = state.index
        var tz = 0
        if idx != 0 {
            var n = idx
            while n & 1 == 0 && tz < numRows - 1 {
                tz += 1
                n >>= 1
            }
        } else {
            tz = numRows - 1
        }

        // Update rows 0…tz with new random values
        for row in 0...tz {
            let oldVal = state.rows[row]
            let newVal = nextRandom(&state.rngState)
            state.rows[row] = newVal
            state.runningSum += (newVal - oldVal)
        }

        state.index = (idx + 1) & 0x3F  // wrap at 64

        // Add one more white noise sample for high-frequency energy
        let white = nextRandom(&state.rngState)
        let pink = (state.runningSum + white) / Double(numRows + 1)

        return Float(pink)
    }

    /// Fast xorshift64 PRNG returning a value in -1…1.
    @inline(__always)
    private static func nextRandom(_ state: inout UInt64) -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        // Map to -1…1
        return Double(Int64(bitPattern: state)) / Double(Int64.max)
    }

    /// Fast xorshift64 PRNG returning a value in 0…1 (for melody scheduling).
    @inline(__always)
    private static func nextRandomUnit(_ state: inout UInt64) -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state) / Double(UInt64.max)
    }

    static func getBassFrequency(pattern: Int, chordIndex: Int) -> Double {
        switch pattern {
        case 1:
            // Pattern 1: Dm7 -> G7 -> Cmaj7 -> A7
            let roots = [73.42, 98.00, 65.41, 55.00] // D2, G2, C2, A1
            return roots[chordIndex % 4]
        case 2:
            // Pattern 2: Fmaj7#11 -> G/F -> Em7 -> Am9
            let roots = [87.31, 98.00, 82.41, 55.00] // F2, G2, E2, A1
            return roots[chordIndex % 4]
        default:
            // Pattern 0: Am7 -> Fmaj7 -> Cmaj7 -> G6
            let roots = [55.00, 87.31, 65.41, 49.00] // A1, F2, C2, G1
            return roots[chordIndex % 4]
        }
    }

    /// Smooth Hermite interpolation S-curve: 3x^2 - 2x^3 (0 <= x <= 1)
    @inline(__always)
    private static func smoothStep(_ x: Double) -> Double {
        let clamped = max(0.0, min(1.0, x))
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }
}
