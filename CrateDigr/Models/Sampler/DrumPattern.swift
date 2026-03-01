import Foundation

struct DrumPattern: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var steps: [[Bool]]    // [padIndex][stepIndex] — 16 pads × 16 steps
    var bpm: Double
    var swing: Double      // 0.0 (straight) to 1.0 (max swing)

    static let stepCount = 16
    static let padCount = 16

    init(name: String = "New Pattern", bpm: Double = 120, swing: Double = 0.0) {
        self.name = name
        self.bpm = bpm
        self.swing = swing
        self.steps = Array(repeating: Array(repeating: false, count: Self.stepCount), count: Self.padCount)
    }

    mutating func toggleStep(pad: Int, step: Int) {
        guard pad < steps.count, step < Self.stepCount else { return }
        steps[pad][step].toggle()
    }

    mutating func clearAll() {
        steps = Array(repeating: Array(repeating: false, count: Self.stepCount), count: Self.padCount)
    }
}
