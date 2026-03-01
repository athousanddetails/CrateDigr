import Foundation
import SwiftUI

struct StemTrack: Identifiable {
    let id = UUID()
    let stemType: StemType
    let fileURL: URL
    let sampleFile: SampleFile
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var volume: Float = 1.0
    var waveformData: [(min: Float, max: Float)] = []
}

enum StemType: String, CaseIterable, Identifiable {
    case vocals
    case drums
    case bass
    case other
    case guitar
    case piano

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .vocals: return "mic"
        case .drums: return "drum"
        case .bass: return "guitars"
        case .other: return "pianokeys"
        case .guitar: return "guitars.fill"
        case .piano: return "pianokeys"
        }
    }

    var color: Color {
        switch self {
        case .vocals: return .purple
        case .drums: return .orange
        case .bass: return .blue
        case .other: return .green
        case .guitar: return .red
        case .piano: return .cyan
        }
    }

    /// Maps demucs.cpp output filename to stem type
    /// Output format: target_0_drums.wav, target_1_bass.wav, etc.
    static func from(demucsFilename: String) -> StemType? {
        let name = demucsFilename
            .replacingOccurrences(of: ".wav", with: "")
            .lowercased()
        if name.contains("drums") { return .drums }
        if name.contains("bass") { return .bass }
        if name.contains("other") { return .other }
        if name.contains("vocals") { return .vocals }
        if name.contains("guitar") { return .guitar }
        if name.contains("piano") { return .piano }
        return nil
    }

    /// Canonical display order
    var sortOrder: Int {
        switch self {
        case .vocals: return 0
        case .drums: return 1
        case .bass: return 2
        case .other: return 3
        case .guitar: return 4
        case .piano: return 5
        }
    }
}
