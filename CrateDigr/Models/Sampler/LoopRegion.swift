import Foundation

struct LoopRegion: Equatable {
    var startSample: Int
    var endSample: Int

    var length: Int {
        endSample - startSample
    }

    var isValid: Bool {
        startSample >= 0 && endSample > startSample
    }

    func durationInSeconds(sampleRate: Double) -> TimeInterval {
        Double(length) / sampleRate
    }

    func durationInBars(sampleRate: Double, bpm: Double) -> Double {
        let seconds = durationInSeconds(sampleRate: sampleRate)
        let beatsPerSecond = bpm / 60.0
        let beats = seconds * beatsPerSecond
        return beats / 4.0  // 4 beats per bar
    }
}
