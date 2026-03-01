import Foundation

struct ZeroCrossingFinder {
    /// Find the nearest zero crossing to the given sample position.
    /// Searches within ±searchWindow samples.
    static func findNearest(
        in samples: [Float],
        near position: Int,
        searchWindow: Int = 512
    ) -> Int {
        guard !samples.isEmpty else { return position }

        let start = max(0, position - searchWindow)
        let end = min(samples.count - 2, position + searchWindow)

        guard start < end else { return position }

        var bestPosition = position
        var bestDistance = Int.max

        for i in start..<end {
            // Check for zero crossing: sign change between consecutive samples
            if samples[i] * samples[i + 1] <= 0 {
                let distance = abs(i - position)
                if distance < bestDistance {
                    bestDistance = distance
                    bestPosition = i
                }
            }
        }

        return bestPosition
    }

    /// Snap both start and end of a loop region to zero crossings
    static func snapLoopRegion(
        in samples: [Float],
        start: Int,
        end: Int,
        searchWindow: Int = 512
    ) -> (start: Int, end: Int) {
        let snappedStart = findNearest(in: samples, near: start, searchWindow: searchWindow)
        let snappedEnd = findNearest(in: samples, near: end, searchWindow: searchWindow)
        return (snappedStart, max(snappedEnd, snappedStart + 1))
    }
}
