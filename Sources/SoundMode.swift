import Foundation

/// Defines the two binaural-beat modes the app supports.
///
/// Each mode specifies a base frequency for the left ear and a slightly
/// different frequency for the right ear. The difference produces the
/// perceived "binaural beat" at the delta frequency.
enum SoundMode: String, CaseIterable, Identifiable, Sendable {
    case relaxation
    case focus

    var id: String { rawValue }

    // MARK: - Frequencies

    /// Frequency sent to the left channel (Hz).
    var leftFrequency: Double {
        switch self {
        case .relaxation: return 200.0
        case .focus:      return 200.0
        }
    }

    /// Frequency sent to the right channel (Hz).
    var rightFrequency: Double {
        switch self {
        case .relaxation: return 208.0   // 8 Hz alpha beat
        case .focus:      return 216.0   // 16 Hz beta beat
        }
    }

    /// The binaural beat frequency perceived by the brain (Hz).
    var beatFrequency: Double {
        rightFrequency - leftFrequency
    }

    // MARK: - Amplitude

    /// Base amplitude (0…1). Focus is slightly louder to feel more energising.
    var amplitude: Double {
        switch self {
        case .relaxation: return 0.12
        case .focus:      return 0.12
        }
    }

    // MARK: - Melody

    /// Pentatonic scale in C (Hz): C3, D3, E3, G3, A3
    static let pentatonicScale: [Double] = [130.81, 146.83, 164.81, 196.00, 220.00]

    /// How many notes from the pentatonic scale this mode uses.
    /// Relaxation prefers lower notes (first 4), Focus uses all 5.
    var melodyScaleCount: Int {
        switch self {
        case .relaxation: return 4
        case .focus:      return 5
        }
    }

    /// Min/max interval between melody notes in seconds.
    var melodyIntervalRange: (min: Double, max: Double) {
        switch self {
        case .relaxation: return (4.0, 8.0)
        case .focus:      return (1.5, 3.0)
        }
    }

    // MARK: - Display

    var title: String {
        switch self {
        case .relaxation: return "Relaxation"
        case .focus:      return "Focus"
        }
    }

    var subtitle: String {
        let beat = Int(beatFrequency)
        let band = self == .relaxation ? "Alpha" : "Beta"
        return "\(beat) Hz \(band)"
    }

    var icon: String {
        switch self {
        case .relaxation: return "🌊"
        case .focus:      return "⚡"
        }
    }

    var frequencyLabel: String {
        "\(Int(leftFrequency)) / \(Int(rightFrequency)) Hz"
    }
}
