import Foundation
import Accelerate

struct TransientDetector {
    /// Detect transient positions in audio samples using spectral flux.
    /// Returns sorted array of sample positions.
    static func detect(
        samples: [Float],
        sampleRate: Double,
        sensitivity: Float = 0.5   // 0.0 (many) to 1.0 (few)
    ) -> [Int] {
        let windowSize = 1024
        let hopSize = 512
        let totalFrames = samples.count

        guard totalFrames > windowSize else { return [] }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: windowSize, isHalfWindow: false)

        // Compute spectral flux
        var fluxValues: [(position: Int, flux: Float)] = []
        var prevMagnitudes = [Float](repeating: 0, count: windowSize / 2)

        var frameStart = 0
        while frameStart + windowSize <= totalFrames {
            var frame = Array(samples[frameStart..<frameStart + windowSize])
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(windowSize))

            let magnitudes = computeMagnitudes(frame)

            // Half-wave rectified spectral flux
            var flux: Float = 0
            for i in 0..<min(magnitudes.count, prevMagnitudes.count) {
                let diff = magnitudes[i] - prevMagnitudes[i]
                if diff > 0 { flux += diff }
            }

            fluxValues.append((position: frameStart + windowSize / 2, flux: flux))
            prevMagnitudes = magnitudes
            frameStart += hopSize
        }

        guard !fluxValues.isEmpty else { return [] }

        // Calculate adaptive threshold
        let allFlux = fluxValues.map(\.flux)
        let meanFlux = allFlux.reduce(0, +) / Float(allFlux.count)
        let maxFlux = allFlux.max() ?? 1.0

        // Threshold: higher sensitivity = higher threshold = fewer detections
        let threshold = meanFlux + (maxFlux - meanFlux) * sensitivity

        // Peak picking: find local maxima above threshold
        var transients: [Int] = []
        let minDistance = Int(sampleRate * 0.05) // Minimum 50ms between transients

        for i in 1..<(fluxValues.count - 1) {
            let current = fluxValues[i].flux
            let prev = fluxValues[i - 1].flux
            let next = fluxValues[i + 1].flux

            if current > threshold && current > prev && current >= next {
                let position = fluxValues[i].position
                // Enforce minimum distance
                if let last = transients.last, position - last < minDistance {
                    continue
                }
                transients.append(position)
            }
        }

        return transients
    }

    /// Detect and return a specific number of evenly-distributed slices
    static func detectWithCount(
        samples: [Float],
        sampleRate: Double,
        targetCount: Int
    ) -> [Int] {
        // Try different sensitivity levels to get close to target count
        var bestResult: [Int] = []
        var bestDiff = Int.max

        for s in stride(from: 0.0, through: 1.0, by: 0.05) {
            let result = detect(samples: samples, sampleRate: sampleRate, sensitivity: Float(s))
            let diff = abs(result.count - targetCount)
            if diff < bestDiff {
                bestDiff = diff
                bestResult = result
            }
            if diff == 0 { break }
        }

        return bestResult
    }

    // MARK: - FFT Helper

    private static func computeMagnitudes(_ frame: [Float]) -> [Float] {
        let n = frame.count
        let log2n = vDSP_Length(log2(Float(n)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            return [Float](repeating: 0, count: n / 2)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                frame.withUnsafeBufferPointer { framePtr in
                    framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }

        var magnitudes = [Float](repeating: 0, count: n / 2)
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        return magnitudes
    }
}
