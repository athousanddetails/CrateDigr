import Foundation
import AVFoundation
import Accelerate

struct SampleFile: Identifiable {
    let id = UUID()
    let url: URL
    let samples: [Float]           // Mono float samples
    let sampleRate: Double
    let channelCount: Int
    let duration: TimeInterval
    var bpm: Int?
    var key: String?
    var scale: String?

    var filename: String {
        url.deletingPathExtension().lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var totalSamples: Int {
        samples.count
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var sampleRateDisplay: String {
        if sampleRate == 44100 { return "44.1kHz" }
        if sampleRate == 48000 { return "48kHz" }
        return "\(Int(sampleRate))Hz"
    }

    var keyDisplay: String? {
        guard let key, let scale else { return nil }
        return "\(key) \(scale)"
    }

    /// Compute downsampled waveform data for display (min/max pairs per bucket)
    /// Uses vDSP for SIMD-accelerated min/max — much faster than scalar loop
    func waveformData(bucketCount: Int) -> [(min: Float, max: Float)] {
        guard !samples.isEmpty, bucketCount > 0 else { return [] }
        let samplesPerBucket = max(1, samples.count / bucketCount)
        var result: [(min: Float, max: Float)] = []
        result.reserveCapacity(bucketCount)

        samples.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            for i in 0..<bucketCount {
                let start = i * samplesPerBucket
                let end = min(start + samplesPerBucket, samples.count)
                let count = end - start
                guard count > 0 else {
                    result.append((0, 0))
                    continue
                }
                var minVal: Float = 0
                var maxVal: Float = 0
                vDSP_minv(base + start, 1, &minVal, vDSP_Length(count))
                vDSP_maxv(base + start, 1, &maxVal, vDSP_Length(count))
                result.append((minVal, maxVal))
            }
        }
        return result
    }

    /// Rekordbox 3-Band frequency data: returns (low, mid, high) amplitude per bucket
    /// Uses proper IIR filtering with Rekordbox cutoffs:
    ///   Low: 20-200Hz (Blue) — kicks, bass
    ///   Mid: 200-5000Hz (Orange/Amber) — vocals, synths, snares
    ///   High: 5000-20000Hz (White) — hats, cymbals, air
    func frequencyColorData(bucketCount: Int) -> [(low: Float, mid: Float, high: Float)] {
        guard !samples.isEmpty, bucketCount > 0 else { return [] }

        // First, run 3-band IIR filter over the entire signal
        let sr = Float(sampleRate)
        let n = samples.count

        // Biquad filter coefficients for 2nd-order Butterworth
        // Low-pass at 200Hz
        let lpCoeffs = biquadLowPass(cutoff: 200.0, sampleRate: sr)
        // High-pass at 5000Hz
        let hpCoeffs = biquadHighPass(cutoff: 5000.0, sampleRate: sr)
        // Band-pass: 200-5000Hz (LP at 5000 minus LP at 200, or use two filters)
        let bpLowCoeffs = biquadLowPass(cutoff: 5000.0, sampleRate: sr)
        let bpHighCoeffs = biquadHighPass(cutoff: 200.0, sampleRate: sr)

        // Filter the signal into 3 bands
        var lowBand = [Float](repeating: 0, count: n)
        var midBand = [Float](repeating: 0, count: n)
        var highBand = [Float](repeating: 0, count: n)

        // Apply low-pass filter for bass band
        applyBiquad(input: samples, output: &lowBand, coeffs: lpCoeffs)

        // Apply band-pass (high-pass 200Hz then low-pass 5000Hz) for mid band
        var midTemp = [Float](repeating: 0, count: n)
        applyBiquad(input: samples, output: &midTemp, coeffs: bpHighCoeffs)
        applyBiquad(input: midTemp, output: &midBand, coeffs: bpLowCoeffs)

        // Apply high-pass filter for treble band
        applyBiquad(input: samples, output: &highBand, coeffs: hpCoeffs)

        // Now downsample each band into buckets (peak amplitude per bucket)
        let samplesPerBucket = max(1, n / bucketCount)
        var result: [(low: Float, mid: Float, high: Float)] = []
        result.reserveCapacity(bucketCount)

        for i in 0..<bucketCount {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, n)
            guard start < end else {
                result.append((0, 0, 0))
                continue
            }

            var lowPeak: Float = 0
            var midPeak: Float = 0
            var highPeak: Float = 0

            for j in start..<end {
                lowPeak = max(lowPeak, abs(lowBand[j]))
                midPeak = max(midPeak, abs(midBand[j]))
                highPeak = max(highPeak, abs(highBand[j]))
            }

            result.append((low: lowPeak, mid: midPeak, high: highPeak))
        }
        return result
    }

    // MARK: - Biquad Filter Helpers (2nd-order Butterworth)

    private struct BiquadCoeffs {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    }

    private func biquadLowPass(cutoff: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * sqrt(2.0)) // Q = sqrt(2)/2 for Butterworth

        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: ((1.0 - cosW0) / 2.0) / a0,
            b1: (1.0 - cosW0) / a0,
            b2: ((1.0 - cosW0) / 2.0) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private func biquadHighPass(cutoff: Float, sampleRate: Float) -> BiquadCoeffs {
        let w0 = 2.0 * Float.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * sqrt(2.0))

        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: ((1.0 + cosW0) / 2.0) / a0,
            b1: -(1.0 + cosW0) / a0,
            b2: ((1.0 + cosW0) / 2.0) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private func applyBiquad(input: [Float], output: inout [Float], coeffs: BiquadCoeffs) {
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0

        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = coeffs.b0 * x0 + coeffs.b1 * x1 + coeffs.b2 * x2
                    - coeffs.a1 * y1 - coeffs.a2 * y2
            output[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
    }

    /// Load a SampleFile from a URL
    static func load(from url: URL) throws -> SampleFile {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else {
            throw SampleFileError.empty
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SampleFileError.cannotCreateBuffer
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw SampleFileError.noData
        }

        let channelCount = Int(format.channelCount)
        var monoSamples = [Float](repeating: 0, count: Int(frameCount))

        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(frameCount)))
        } else {
            // Mix to mono
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in 0..<Int(frameCount) {
                    monoSamples[i] += ptr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<monoSamples.count {
                monoSamples[i] *= scale
            }
        }

        let duration = Double(frameCount) / format.sampleRate

        return SampleFile(
            url: url,
            samples: monoSamples,
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            duration: duration
        )
    }

    enum SampleFileError: LocalizedError {
        case empty, cannotCreateBuffer, noData

        var errorDescription: String? {
            switch self {
            case .empty: return "Audio file is empty"
            case .cannotCreateBuffer: return "Cannot create audio buffer"
            case .noData: return "No audio data found"
            }
        }
    }
}
