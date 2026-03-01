import Foundation

struct SliceMarker: Identifiable, Equatable {
    let id = UUID()
    var samplePosition: Int     // Position in samples
    var type: MarkerType
    var padIndex: Int?           // Assigned MPC pad (0-15)

    enum MarkerType: String, Equatable {
        case transient   // Auto-detected
        case manual      // User placed
        case grid        // Grid-based
    }
}
