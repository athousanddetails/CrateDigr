import Foundation
import Accelerate

struct SpectrogramData {
    let magnitudes: [[Float]]  // [timeSlice][frequencyBin]
    let frequencyBinCount: Int
    let timeSliceCount: Int
    let maxMagnitude: Float
}

struct SpectrogramComputer {
    /// Compute spectrogram data from audio samples.
    /// Returns a 2D magnitude matrix (time × frequency) in dB scale.
    static func compute(
        samples: [Float],
        sampleRate: Double,
        fftSize: Int = 2048,
        targetTimeSlices: Int = 2000
    ) -> SpectrogramData {
        let totalFrames = samples.count
        guard totalFrames > fftSize else {
            return SpectrogramData(magnitudes: [], frequencyBinCount: 0, timeSliceCount: 0, maxMagnitude: 0)
        }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            return SpectrogramData(magnitudes: [], frequencyBinCount: 0, timeSliceCount: 0, maxMagnitude: 0)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hanning window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let binCount = fftSize / 2

        // Adjust hop to get approximately targetTimeSlices
        let hopSize = max(256, totalFrames / targetTimeSlices)

        var allMagnitudes: [[Float]] = []
        var maxMag: Float = -Float.greatestFiniteMagnitude

        var realPart = [Float](repeating: 0, count: binCount)
        var imagPart = [Float](repeating: 0, count: binCount)
        var windowedFrame = [Float](repeating: 0, count: fftSize)

        var frameStart = 0
        while frameStart + fftSize <= totalFrames {
            // Window the frame
            vDSP_vmul(Array(samples[frameStart..<frameStart + fftSize]), 1, window, 1, &windowedFrame, 1, vDSP_Length(fftSize))

            // FFT
            windowedFrame.withUnsafeBufferPointer { framePtr in
                framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { complexPtr in
                    realPart.withUnsafeMutableBufferPointer { realBuf in
                        imagPart.withUnsafeMutableBufferPointer { imagBuf in
                            var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(binCount))
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }

            // Compute magnitudes
            var magnitudes = [Float](repeating: 0, count: binCount)
            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(binCount))
                }
            }

            // Convert to dB scale
            for i in 0..<binCount {
                magnitudes[i] = 10.0 * log10(max(magnitudes[i], 1e-10))
            }

            let sliceMax = magnitudes.max() ?? -80
            if sliceMax > maxMag { maxMag = sliceMax }

            allMagnitudes.append(magnitudes)
            frameStart += hopSize
        }

        return SpectrogramData(
            magnitudes: allMagnitudes,
            frequencyBinCount: binCount,
            timeSliceCount: allMagnitudes.count,
            maxMagnitude: maxMag
        )
    }
}
