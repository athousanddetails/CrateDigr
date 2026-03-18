import Foundation
import Accelerate

/// Multi-resolution waveform data pyramid for smooth rendering at all zoom levels.
/// Pre-computes 5 LOD levels so the renderer always has ~1-2 buckets per pixel.
final class WaveformLOD {
    struct Level {
        let bucketCount: Int
        let mono: [(min: Float, max: Float)]
        let stereo: [(leftMin: Float, leftMax: Float, rightMin: Float, rightMax: Float)]
        let color: [(low: Float, mid: Float, high: Float)]
    }

    static let bucketCounts = [500, 2_000, 8_000, 32_000, 128_000]

    private(set) var levels: [Level] = []
    private(set) var isComplete = false

    /// Compute all LOD levels from a SampleFile.
    /// Levels 0-2 are computed synchronously (fast). Levels 3-4 are added via the completion callback.
    static func compute(from file: SampleFile, onHighResReady: @escaping (WaveformLOD) -> Void) -> WaveformLOD {
        let lod = WaveformLOD()

        // Compute low-res levels synchronously (fast — small bucket counts)
        for i in 0..<3 {
            let count = bucketCounts[i]
            let mono = file.waveformData(bucketCount: count)
            let stereo = file.waveformDataStereo(bucketCount: count)
            let color = file.frequencyColorData(bucketCount: count)
            lod.levels.append(Level(bucketCount: count, mono: mono, stereo: stereo, color: color))
        }

        // Compute high-res levels in background
        Task.detached(priority: .userInitiated) {
            for i in 3..<bucketCounts.count {
                let count = bucketCounts[i]
                let mono = file.waveformData(bucketCount: count)
                let stereo = file.waveformDataStereo(bucketCount: count)
                let color = file.frequencyColorData(bucketCount: count)
                await MainActor.run {
                    lod.levels.append(Level(bucketCount: count, mono: mono, stereo: stereo, color: color))
                    if i == bucketCounts.count - 1 {
                        lod.isComplete = true
                    }
                    onHighResReady(lod)
                }
            }
        }

        return lod
    }

    /// Select the best LOD level for the current zoom and view width.
    /// Returns the level index where bucket density best matches pixel density.
    func selectLevel(zoom: CGFloat, viewWidth: CGFloat, totalSamples: Int) -> Int {
        guard !levels.isEmpty, totalSamples > 0, viewWidth > 0 else { return 0 }

        // How many samples are visible on screen
        let visibleSamples = Double(totalSamples) / Double(zoom)
        // Ideal bucket count = one bucket per pixel for the visible range
        let idealBuckets = Double(viewWidth) * Double(totalSamples) / visibleSamples

        var bestLevel = 0
        var bestDist = Double.infinity

        for (i, level) in levels.enumerated() {
            let dist = abs(Double(level.bucketCount) - idealBuckets)
            // Prefer higher resolution when close
            if dist < bestDist || (dist == bestDist && level.bucketCount > levels[bestLevel].bucketCount) {
                bestDist = dist
                bestLevel = i
            }
        }

        return bestLevel
    }
}
