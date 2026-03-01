import Foundation

enum PitchSpeedMode: String, CaseIterable, Identifiable {
    case turntable    // Coupled: speed change = pitch change (vinyl behavior) — "Repitch"
    case independent  // Decoupled: speed and pitch adjustable independently
    case beats        // Optimized for rhythmic material, preserves transients
    case complex      // High-quality for full mixes, preserves everything
    case texture      // For pads/ambient, smears transients for smooth stretching

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turntable: return "Repitch"
        case .independent: return "Independent"
        case .beats: return "Beats"
        case .complex: return "Complex"
        case .texture: return "Texture"
        }
    }

    var description: String {
        switch self {
        case .turntable: return "Speed and pitch change together — vinyl / turntable style"
        case .independent: return "Adjust speed and pitch separately — general purpose"
        case .beats: return "Optimized for drums & rhythmic material — preserves transients"
        case .complex: return "Highest quality for full mixes — preserves harmonics & timing"
        case .texture: return "For pads & ambient — smooth stretching, smears transients"
        }
    }

    /// Short label for the Digitakt-style display
    var shortLabel: String {
        switch self {
        case .turntable: return "RPTCH"
        case .independent: return "INDEP"
        case .beats: return "BEATS"
        case .complex: return "CMPLX"
        case .texture: return "TXTUR"
        }
    }
}
