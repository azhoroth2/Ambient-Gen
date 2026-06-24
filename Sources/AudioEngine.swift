@preconcurrency import AVFoundation
import Observation

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
    }

    var voices: [Voice] = [Voice(), Voice(), Voice(), Voice(), Voice()]
    var activeVoiceIndex: Int = -1

    // Timer: samples remaining until next note trigger
    var samplesUntilNext: Int = 44100   // ~1s initial delay before first note

    // PRNG (separate seed from pink noise)
    var rngState: UInt64 = 0xCAFE_BABE_DEAD_BEEF

    // Wow & Flutter LFO phases
    var wowPhase: Double = 0.0
    var flutterPhase: Double = 0.0
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

    // MARK: - Private Audio Graph

    private let engine = AVAudioEngine()
    private var oscNode: AVAudioSourceNode?
    private var noiseNode: AVAudioSourceNode?
    private var melodyNode: AVAudioSourceNode?
    private var drumNode: AVAudioSourceNode?
    private let reverb = AVAudioUnitReverb()

    // MARK: - DSP State (shared with render thread)

    private let dsp = DSPState()
    private let noiseDsp = PinkNoiseState()
    private let melodyDsp = MelodyState()
    private let drumDsp = DrumState()
    private var fadeTask: Task<Void, Never>?

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
    private static let pentatonicScale: [Double] = [130.81, 146.83, 164.81, 196.00, 220.00]

    // MARK: - Lifecycle

    init() {}

    // MARK: - Public API

    @MainActor
    func start() {
        fadeTask?.cancel()
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
        
        fadeTask = Task {
            let duration = 1.5 // seconds
            let steps = 50
            let interval = duration / Double(steps)
            let startVol = Double(engine.mainMixerNode.outputVolume)
            
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let vol = startVol + (1.0 - startVol) * t
                engine.mainMixerNode.outputVolume = Float(vol)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            engine.mainMixerNode.outputVolume = 1.0
        }
    }

    @MainActor
    func stop() {
        fadeTask?.cancel()
        
        guard isPlaying else { return }
        isPlaying = false
        
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
            self.drumDsp.kickTime = -1.0
            self.drumDsp.snareTime = -1.0
            self.drumDsp.hatTime = -1.0
            self.drumDsp.kickEnvelope = 0.0
            self.drumDsp.snareEnvelope = 0.0
            self.drumDsp.hatEnvelope = 0.0
            self.drumDsp.currentStep = 0
            self.drumDsp.samplesUntilNextStep = 88200
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
        let silenceChance = Self.melodySilenceChance
        let detuneRange = Self.melodyDetune
        let scale = Self.pentatonicScale

        let melody = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)

            let twoPi = 2.0 * Double.pi

            for frame in 0..<Int(frameCount) {
                // ── Note scheduling ──
                melDsp.samplesUntilNext -= 1
                if melDsp.samplesUntilNext <= 0 {
                    // Transition current active voice (if any and if playing) to release
                    let activeIdx = melDsp.activeVoiceIndex
                    if activeIdx >= 0 && activeIdx < 5 {
                        if melDsp.voices[activeIdx].stage != 0 && melDsp.voices[activeIdx].stage != 4 {
                            melDsp.voices[activeIdx].stage = 4 // Release
                            melDsp.voices[activeIdx].startReleaseLevel = melDsp.voices[activeIdx].envelopeValue
                            let rTime = melDsp.voices[activeIdx].releaseTime
                            melDsp.voices[activeIdx].releaseRate = melDsp.voices[activeIdx].envelopeValue / (rTime * sampleRate)
                        }
                        melDsp.activeVoiceIndex = -1
                    }

                    // Read mode-dependent parameters
                    let scaleCount = 5
                    let minInterval = 3.0
                    let maxInterval = 6.0

                    // Decide: note or silence?
                    let chance = Self.nextRandomUnit(&melDsp.rngState)
                    if chance > silenceChance {
                        // Pick a random note from the allowed range
                        let noteIdx = Int(Self.nextRandomUnit(&melDsp.rngState) * Double(scaleCount)) % scaleCount
                        
                        // Octave randomization:
                        // 60% chance base octave (multiplier 1.0)
                        // 30% chance octave up (multiplier 2.0)
                        // 10% chance octave down (multiplier 0.5)
                        let octaveChance = Self.nextRandomUnit(&melDsp.rngState)
                        var octaveMultiplier = 1.0
                        if octaveChance > 0.9 {
                            octaveMultiplier = 0.5
                        } else if octaveChance > 0.6 {
                            octaveMultiplier = 2.0
                        }
                        
                        // Apply micro-detune: ±1.5 Hz random offset
                        let detune = (Self.nextRandomUnit(&melDsp.rngState) * 2.0 - 1.0) * detuneRange
                        let frequency = (scale[noteIdx] * octaveMultiplier) + detune

                        // Randomize amplitude factor (0.7 to 1.0)
                        let ampFactor = 0.7 + Self.nextRandomUnit(&melDsp.rngState) * 0.3

                        // Randomize Attack Time (1.0 to 2.0 seconds)
                        let randomizedAttackTime = 1.0 + Self.nextRandomUnit(&melDsp.rngState) * 1.0
                        let attackRate = 1.0 / (randomizedAttackTime * sampleRate)

                        // Randomize Decay Time (0.4 to 0.6 seconds)
                        let randomizedDecayTime = 0.4 + Self.nextRandomUnit(&melDsp.rngState) * 0.2
                        let decayRate = 0.2 / (randomizedDecayTime * sampleRate)

                        // Randomize Release Time (3.0 to 5.0 seconds)
                        let randomizedReleaseTime = 3.0 + Self.nextRandomUnit(&melDsp.rngState) * 2.0

                        // Find a voice: idle first, then lowest envelope value
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
                            melDsp.voices[selectedVoiceIndex].frequency = frequency
                            melDsp.voices[selectedVoiceIndex].phase = 0.0
                            melDsp.voices[selectedVoiceIndex].envelopeValue = 0.0
                            melDsp.voices[selectedVoiceIndex].stage = 1 // Attack
                            
                            melDsp.voices[selectedVoiceIndex].amplitudeFactor = ampFactor
                            melDsp.voices[selectedVoiceIndex].attackRate = attackRate
                            melDsp.voices[selectedVoiceIndex].decayRate = decayRate
                            melDsp.voices[selectedVoiceIndex].releaseTime = randomizedReleaseTime
                            
                            melDsp.activeVoiceIndex = selectedVoiceIndex
                        }
                    }

                    // Schedule next trigger
                    let intervalRange = maxInterval - minInterval
                    let nextInterval = minInterval + Self.nextRandomUnit(&melDsp.rngState) * intervalRange
                    melDsp.samplesUntilNext = Int(nextInterval * sampleRate)
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
                        // Remains 0.8 until release starts
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
                    drumDsp.samplesUntilNextStep = 8269 // 16th step at 80 BPM
                    
                    let step = drumDsp.currentStep
                    
                    // Procedural Boom-Bap sequencer rules (probabilistic & organic)
                    // Kick probability:
                    var triggerKick = false
                    if step == 0 {
                        triggerKick = true // Downbeat is guaranteed
                    } else if step == 8 {
                        triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.90 // 90% chance
                    } else if step == 10 {
                        triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.70 // 70% chance of double kick syncopation
                    } else if step == 6 || step == 14 {
                        triggerKick = Self.nextRandomUnit(&drumDsp.rngState) < 0.15 // 15% chance of a ghost kick
                    }
                    
                    if triggerKick {
                        drumDsp.kickTime = 0.0
                        drumDsp.kickPhase = 0.0
                    }
                    
                    // Snare probability:
                    var triggerSnare = false
                    if step == 4 || step == 12 {
                        triggerSnare = true // Backbeat is guaranteed
                    } else if step == 15 {
                        triggerSnare = Self.nextRandomUnit(&drumDsp.rngState) < 0.20 // 20% chance of a fill/pickup snare
                    }
                    
                    if triggerSnare {
                        drumDsp.snareTime = 0.0
                        drumDsp.snarePhase = 0.0
                    }
                    
                    // Hi-Hat probability & rolls:
                    // Usually plays on even steps, but occasionally plays sixteenth notes or rolls
                    var triggerHat = false
                    var accent = false
                    if step % 2 == 0 {
                        triggerHat = Self.nextRandomUnit(&drumDsp.rngState) < 0.95 // 95% on-beat hat
                        accent = (step % 4 == 0)
                    } else {
                        // 15% chance of a 16th note subdivision (hi-hat roll/fill)
                        triggerHat = Self.nextRandomUnit(&drumDsp.rngState) < 0.18
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
                    // Exponential pitch sweep from 150Hz to 48Hz
                    let freq = 48.0 + 102.0 * exp(-drumDsp.kickTime * 45.0)
                    drumDsp.kickPhase += 2.0 * Double.pi * freq / sampleRate
                    let kickVal = sin(drumDsp.kickPhase)
                    let kickEnv = exp(-drumDsp.kickTime * 18.0)
                    sample += Float(kickVal * kickEnv * 0.22)
                    
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
                    // Low tone body (185 Hz)
                    drumDsp.snarePhase += 2.0 * Double.pi * 185.0 / sampleRate
                    let snareVal = sin(drumDsp.snarePhase)
                    let bodyEnv = exp(-drumDsp.snareTime * 38.0)
                    
                    // Snare white noise rattle
                    let noiseVal = Self.nextRandom(&drumDsp.rngState)
                    let noiseEnv = exp(-drumDsp.snareTime * 14.0)
                    
                    // Mix body and noise
                    let snareMix = snareVal * bodyEnv * 0.35 + noiseVal * noiseEnv * 0.65
                    sample += Float(snareMix * 0.12)
                    
                    drumDsp.snareEnvelope = bodyEnv * 0.35 + noiseEnv * 0.65
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
                    // High-pass filter (DC blocker difference)
                    let hatVal = noiseVal - drumDsp.hatLastNoise
                    drumDsp.hatLastNoise = noiseVal
                    
                    let hatEnv = exp(-drumDsp.hatTime * 85.0)
                    sample += Float(hatVal * hatEnv * drumDsp.hatVolume)
                    
                    drumDsp.hatEnvelope = hatEnv
                    drumDsp.hatTime += 1.0 / sampleRate
                    if drumDsp.hatTime > 0.05 {
                        drumDsp.hatTime = -1.0
                        drumDsp.hatEnvelope = 0.0
                    }
                } else {
                    drumDsp.hatEnvelope = 0.0
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

        // ── 5. Reverb ───────────────────────────────────────────────

        reverb.loadFactoryPreset(.largeChamber)
        reverb.wetDryMix = 55

        // ── 6. Wire the graph ───────────────────────────────────────
        //
        //   osc  ──→ mainMixer ←── noise
        //                ↑
        //              melody
        //                ↑
        //              drums
        //                │
        //             reverb
        //                │
        //             output

        let mixer = engine.mainMixerNode

        engine.attach(osc)
        engine.attach(noise)
        engine.attach(melody)
        engine.attach(drums)
        engine.attach(reverb)

        engine.connect(osc, to: mixer, format: stereoFormat)
        engine.connect(noise, to: mixer, format: stereoFormat)
        engine.connect(melody, to: mixer, format: stereoFormat)
        engine.connect(drums, to: mixer, format: stereoFormat)

        // Adjust connection volumes like a mixer (75% reduction for oscillators, and further reduction for pink noise)
        osc.volume = 0.25
        noise.volume = 0.15
        drums.volume = 0.20 // Cozy background volume

        // Disconnect default mixer→output, insert reverb in between
        engine.disconnectNodeOutput(mixer)
        engine.connect(mixer, to: reverb, format: stereoFormat)
        engine.connect(reverb, to: engine.outputNode, format: stereoFormat)

        oscNode = osc
        noiseNode = noise
        melodyNode = melody
        drumNode = drums

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

    /// Smooth Hermite interpolation S-curve: 3x^2 - 2x^3 (0 <= x <= 1)
    @inline(__always)
    private static func smoothStep(_ x: Double) -> Double {
        let clamped = max(0.0, min(1.0, x))
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }
}
